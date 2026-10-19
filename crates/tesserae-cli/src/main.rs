// Tesserae: a disk-space visualizer.
// Copyright (C) 2026 Stephen de la Vega. All rights reserved.
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

//! `tesserae-cli`: scan a directory tree with the engine and print what it
//! found. A developer tool for checking the engine against a real volume
//! before there is a UI to do it; it is not shipped.
//!
//! It is deliberately thin. Parse the arguments, build [`WalkOptions`], run
//! [`walk_with_progress`], [`try_freeze`], print. Nothing here measures,
//! repairs or hides anything the engine reports: every field of
//! [`WalkStats`] that says the result may be short is printed.
//!
//! # Exit status
//!
//! * `0`: the scan completed (`WalkStats::incomplete` is `None`). Directories
//!   that could not be read for lack of permission, mount points that were
//!   not entered and the depth cap are reported, but they are the scan's
//!   policy and not a reason it stopped, so they do not change the status.
//! * `2`: the scan returned a partial result (cancelled, stalled, out of
//!   memory or descriptors, node budget, malformed batch). The totals are
//!   printed anyway, with the reason.
//! * `1`: nothing was scanned (the root could not be opened, bad arguments,
//!   the snapshot could not be built).
//!
//! # JSON
//!
//! `--json` prints one object with exactly these keys: `path`, `complete`,
//! `dirs`, `files`, `logical_bytes`, `allocated_bytes`, `elapsed`
//! (`walk_secs`, `freeze_secs`, `total_secs`), `incomplete` (the variant name
//! or `null`), `stalled_at`, `unreadable`, `skipped_mounts` (`path`,
//! `reason`), `lost_entries`, `hardlink_dups`, `depth_capped`, `errors`.
//! Paths are not guaranteed to be UTF-8; they are written lossily
//! (invalid bytes become U+FFFD), because JSON strings cannot carry them.

use std::ffi::OsString;
use std::io;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::{Duration, Instant};

use serde_json::{json, Value};
use tesserae_core::freeze::try_freeze;
use tesserae_core::node::{Snapshot, NODE_NONE};
use tesserae_core::progress::{walk_with_progress, Progress};
use tesserae_core::walk::{os_errno, WalkOptions};

const USAGE: &str = "usage: tesserae-cli scan <path> [--json] [--workers N] [--max-depth N] [--node-budget N]\n       tesserae-cli --help";

const HELP: &str = "\
tesserae-cli: scan a directory tree with the Tesserae engine

usage: tesserae-cli scan <path> [--json] [--workers N] [--max-depth N] [--node-budget N]
       tesserae-cli --help

Prints the directory and file counts, the logical and allocated byte totals,
the elapsed time and every field that says the result may be short:
incomplete, stalled_at, unreadable, skipped_mounts, lost_entries,
hardlink_dups, depth_capped and errors.

options:
  --json              print one JSON object instead of text. Output paths
                      are lossy: bytes that are not valid UTF-8 become
                      U+FFFD, in text and JSON alike.
  --workers N         worker threads (default: from the core count, 4 to 16)
  --max-depth N       deepest level recorded; deeper directories are counted
                      in depth_capped and not entered
  --node-budget N     most nodes the walk may store; a walk that hits it is
                      incomplete (this is how exit status 2 is provoked)

exit status:
  0  the scan completed
  2  the scan is partial; the totals are printed with the reason
  1  nothing was scanned: bad arguments, an unopenable root, or no memory
";

/// The longest list of paths text output prints; `--json` has them all.
const TEXT_LIST_LIMIT: usize = 20;

#[derive(Debug, PartialEq)]
enum Invocation {
    Help,
    Scan(ScanArgs),
}

#[derive(Debug, PartialEq)]
struct ScanArgs {
    path: PathBuf,
    json: bool,
    workers: Option<usize>,
    max_depth: Option<u16>,
    node_budget: Option<u64>,
}

/// Parse the arguments after the program name. The error is the message to
/// print above the usage line.
fn parse_args(args: impl IntoIterator<Item = OsString>) -> Result<Invocation, String> {
    let mut args = args.into_iter();
    match args.next() {
        None => return Err("no command given".into()),
        Some(a) if a == "--help" || a == "-h" => return Ok(Invocation::Help),
        Some(a) if a == "scan" => {}
        Some(a) => return Err(format!("unknown command {a:?}")),
    }
    let mut path = None;
    let mut parsed = ScanArgs {
        path: PathBuf::new(),
        json: false,
        workers: None,
        max_depth: None,
        node_budget: None,
    };
    while let Some(arg) = args.next() {
        let flag = arg.to_str().filter(|a| a.starts_with("--"));
        match flag {
            Some("--json") => parsed.json = true,
            Some("--workers") => parsed.workers = Some(number("--workers", args.next())?),
            Some("--max-depth") => parsed.max_depth = Some(number("--max-depth", args.next())?),
            Some("--node-budget") => {
                parsed.node_budget = Some(number("--node-budget", args.next())?);
            }
            Some(other) => return Err(format!("unknown option {other}")),
            None if path.is_none() => path = Some(PathBuf::from(arg)),
            None => return Err(format!("unexpected argument {arg:?}")),
        }
    }
    parsed.path = path.ok_or("scan needs a path")?;
    Ok(Invocation::Scan(parsed))
}

fn number<T: std::str::FromStr>(flag: &str, value: Option<OsString>) -> Result<T, String> {
    let value = value.ok_or_else(|| format!("{flag} needs a value"))?;
    value
        .to_str()
        .and_then(|v| v.parse().ok())
        .ok_or_else(|| format!("{flag}: {value:?} is not a valid number"))
}

/// A path as text. Lossy by design: see the module note on JSON.
fn path_text(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

/// `1234567` as `1.2 MiB`.
fn human(bytes: u64) -> String {
    const UNITS: [&str; 6] = ["KiB", "MiB", "GiB", "TiB", "PiB", "EiB"];
    if bytes < 1024 {
        return format!("{bytes} B");
    }
    let mut value = bytes as f64;
    let mut unit = "B";
    for next in UNITS {
        if value < 1024.0 {
            break;
        }
        value /= 1024.0;
        unit = next;
    }
    format!("{value:.1} {unit}")
}

/// What a finished scan reports.
struct Report {
    path: PathBuf,
    snapshot: Snapshot,
    walk: Duration,
    freeze: Duration,
}

impl Report {
    /// `(logical, allocated)` rolled up at the root; zero for an empty snapshot.
    fn totals(&self) -> (u64, u64) {
        match self.snapshot.root {
            NODE_NONE => (0, 0),
            root => {
                let node = &self.snapshot.nodes[root as usize];
                (node.logical, node.allocated)
            }
        }
    }

    fn complete(&self) -> bool {
        self.snapshot.stats.incomplete.is_none()
    }

    fn json(&self) -> Value {
        let stats = &self.snapshot.stats;
        let (logical, allocated) = self.totals();
        json!({
            "path": path_text(&self.path),
            "complete": self.complete(),
            "dirs": stats.dirs,
            "files": stats.files,
            "logical_bytes": logical,
            "allocated_bytes": allocated,
            "elapsed": {
                "walk_secs": self.walk.as_secs_f64(),
                "freeze_secs": self.freeze.as_secs_f64(),
                "total_secs": (self.walk + self.freeze).as_secs_f64(),
            },
            "incomplete": stats.incomplete.map(|i| format!("{i:?}")),
            "stalled_at": stats.stalled_at.as_deref().map(path_text),
            "unreadable": stats.unreadable.iter().map(|p| path_text(p)).collect::<Vec<_>>(),
            "skipped_mounts": stats
                .skipped_mounts
                .iter()
                .map(|(p, why)| json!({ "path": path_text(p), "reason": format!("{why:?}") }))
                .collect::<Vec<_>>(),
            "lost_entries": stats.lost_entries,
            "hardlink_dups": stats.hardlink_dups,
            "depth_capped": stats.depth_capped,
            "errors": stats.errors,
        })
    }

    fn text(&self) -> String {
        let stats = &self.snapshot.stats;
        let (logical, allocated) = self.totals();
        let mut out = format!("scanned: {}\n", path_text(&self.path));
        let mut line = |label: &str, value: String| {
            out.push_str(&format!("{:<16}{value}\n", format!("{label}:")));
        };
        line("dirs", stats.dirs.to_string());
        line("files", stats.files.to_string());
        line("logical", format!("{logical} bytes ({})", human(logical)));
        line(
            "allocated",
            format!("{allocated} bytes ({})", human(allocated)),
        );
        line(
            "elapsed",
            format!(
                "{:.3} s (walk {:.3} s, freeze {:.3} s)",
                (self.walk + self.freeze).as_secs_f64(),
                self.walk.as_secs_f64(),
                self.freeze.as_secs_f64()
            ),
        );
        line(
            "incomplete",
            stats.incomplete.map_or("no".into(), |i| format!("{i:?}")),
        );
        line(
            "stalled_at",
            stats.stalled_at.as_deref().map_or("-".into(), path_text),
        );
        line("unreadable", stats.unreadable.len().to_string());
        line("skipped_mounts", stats.skipped_mounts.len().to_string());
        line("lost_entries", stats.lost_entries.to_string());
        line("hardlink_dups", stats.hardlink_dups.to_string());
        line("depth_capped", stats.depth_capped.to_string());
        line("errors", stats.errors.to_string());

        let mut list = |title: &str, items: Vec<String>| {
            if items.is_empty() {
                return;
            }
            out.push_str(&format!("\n{title}:\n"));
            for item in items.iter().take(TEXT_LIST_LIMIT) {
                out.push_str(&format!("  {item}\n"));
            }
            if items.len() > TEXT_LIST_LIMIT {
                out.push_str(&format!(
                    "  ... and {} more (--json lists them all)\n",
                    items.len() - TEXT_LIST_LIMIT
                ));
            }
        };
        list(
            "unreadable (permission denied)",
            stats.unreadable.iter().map(|p| path_text(p)).collect(),
        );
        list(
            "skipped mounts",
            stats
                .skipped_mounts
                .iter()
                .map(|(p, why)| format!("{} ({why:?})", path_text(p)))
                .collect(),
        );
        out
    }
}

/// `error: <message>`, with the OS error number when there is one.
fn describe(err: &io::Error) -> String {
    match os_errno(err) {
        Some(errno) => format!("{err} (errno {errno})"),
        None => err.to_string(),
    }
}

fn scan(args: &ScanArgs) -> Result<Report, String> {
    let mut opts = WalkOptions {
        root: args.path.clone(),
        ..WalkOptions::default()
    };
    if let Some(workers) = args.workers {
        opts.workers = workers;
    }
    if let Some(max_depth) = args.max_depth {
        opts.max_depth = max_depth;
    }
    if let Some(node_budget) = args.node_budget {
        opts.node_budget = node_budget;
    }

    // `try_freeze`, never `freeze`: a volume too big to snapshot is an exit
    // status here, not a panic.
    let progress = Progress::default();
    let started = Instant::now();
    let (arenas, stats) = walk_with_progress(&opts, &progress).map_err(|e| describe(&e))?;
    let walk = started.elapsed();
    let frozen = Instant::now();
    let snapshot = try_freeze(arenas, stats)
        .map_err(|e| format!("building the snapshot of {}: {e}", args.path.display()))?;
    Ok(Report {
        path: args.path.clone(),
        snapshot,
        walk,
        freeze: frozen.elapsed(),
    })
}

fn main() -> ExitCode {
    let args = match parse_args(std::env::args_os().skip(1)) {
        Ok(Invocation::Help) => {
            print!("{HELP}");
            return ExitCode::SUCCESS;
        }
        Ok(Invocation::Scan(args)) => args,
        Err(message) => {
            eprintln!("error: {message}\n{USAGE}");
            return ExitCode::from(1);
        }
    };
    match scan(&args) {
        Ok(report) => {
            if args.json {
                match serde_json::to_string_pretty(&report.json()) {
                    Ok(text) => println!("{text}"),
                    Err(e) => {
                        eprintln!("error: writing JSON: {e}");
                        return ExitCode::from(1);
                    }
                }
            } else {
                print!("{}", report.text());
            }
            if report.complete() {
                ExitCode::SUCCESS
            } else {
                ExitCode::from(2)
            }
        }
        Err(message) => {
            eprintln!("error: {message}");
            ExitCode::from(1)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::ffi::OsStrExt;
    use tesserae_core::boundary::SkipReason;
    use tesserae_core::walk::{Incomplete, WalkStats};

    fn args(list: &[&str]) -> Vec<OsString> {
        list.iter().map(OsString::from).collect()
    }

    #[test]
    fn a_path_that_is_not_utf8_is_written_lossily_not_dropped_or_fatal() {
        let path = Path::new(std::ffi::OsStr::from_bytes(b"/tmp/caf\xe9/x"));
        // Precondition: it really is not UTF-8.
        assert!(path.to_str().is_none());
        assert_eq!(path_text(path), "/tmp/caf\u{FFFD}/x");
        // And JSON accepts the result, which a raw `PathBuf` would not.
        assert!(serde_json::to_string(&path_text(path)).is_ok());
        assert!(serde_json::to_string(&path).is_err());
    }

    #[test]
    fn a_scan_path_that_is_not_utf8_is_accepted_as_given() {
        let raw = std::ffi::OsStr::from_bytes(b"caf\xe9").to_os_string();
        let parsed = parse_args([OsString::from("scan"), raw.clone()]).unwrap();
        match parsed {
            Invocation::Scan(a) => assert_eq!(a.path.as_os_str(), raw),
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn options_parse_in_any_order_around_the_path() {
        let parsed = parse_args(args(&[
            "scan",
            "--json",
            "/x",
            "--workers",
            "3",
            "--max-depth",
            "7",
            "--node-budget",
            "99",
        ]))
        .unwrap();
        assert_eq!(
            parsed,
            Invocation::Scan(ScanArgs {
                path: "/x".into(),
                json: true,
                workers: Some(3),
                max_depth: Some(7),
                node_budget: Some(99),
            })
        );
    }

    /// A result no fixture can produce on demand (a stall, lost entries, races)
    /// with a different number in every field, so a field printed under another
    /// field's name cannot pass.
    fn synthetic_report() -> Report {
        let stats = WalkStats {
            dirs: 13,
            files: 17,
            errors: 11,
            unreadable: vec!["/v/locked".into()],
            skipped_mounts: vec![("/v/mnt".into(), SkipReason::NonLocalMount)],
            depth_capped: 7,
            lost_entries: 3,
            hardlink_dups: 5,
            stalled_at: Some("/v/hung".into()),
            incomplete: Some(Incomplete::Stalled),
        };
        Report {
            path: "/v".into(),
            snapshot: Snapshot {
                nodes: Vec::new(),
                names: Vec::new(),
                root: NODE_NONE,
                stats,
            },
            walk: Duration::from_millis(1500),
            freeze: Duration::from_millis(500),
        }
    }

    #[test]
    fn json_maps_every_stats_field_to_its_own_key() {
        let json = synthetic_report().json();
        assert_eq!(
            json,
            json!({
                "path": "/v",
                "complete": false,
                "dirs": 13,
                "files": 17,
                "logical_bytes": 0,
                "allocated_bytes": 0,
                "elapsed": { "walk_secs": 1.5, "freeze_secs": 0.5, "total_secs": 2.0 },
                "incomplete": "Stalled",
                "stalled_at": "/v/hung",
                "unreadable": ["/v/locked"],
                "skipped_mounts": [{ "path": "/v/mnt", "reason": "NonLocalMount" }],
                "lost_entries": 3,
                "hardlink_dups": 5,
                "depth_capped": 7,
                "errors": 11,
            })
        );
    }

    #[test]
    fn text_maps_every_stats_field_to_its_own_line() {
        let text = synthetic_report().text();
        for line in [
            "dirs:           13",
            "files:          17",
            "incomplete:     Stalled",
            "stalled_at:     /v/hung",
            "unreadable:     1",
            "skipped_mounts: 1",
            "lost_entries:   3",
            "hardlink_dups:  5",
            "depth_capped:   7",
            "errors:         11",
            "  /v/locked",
            "  /v/mnt (NonLocalMount)",
        ] {
            assert!(text.lines().any(|l| l == line), "no {line:?} in:\n{text}");
        }
    }

    #[test]
    fn sizes_are_humanised_with_binary_units() {
        assert_eq!(human(0), "0 B");
        assert_eq!(human(1023), "1023 B");
        assert_eq!(human(1024), "1.0 KiB");
        assert_eq!(human(5 * 1024 * 1024 * 1024 + 512 * 1024 * 1024), "5.5 GiB");
    }
}
