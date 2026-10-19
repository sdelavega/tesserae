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

//! `tesserae-cli` run as a real process against real trees.
//!
//! The expectations come from `std::fs` metadata, not from the engine the CLI
//! drives: the point is that the numbers the CLI prints are the numbers the
//! filesystem holds, and that a failure reaches the exit status.

use std::collections::HashMap;
use std::os::unix::fs::MetadataExt;
use std::path::Path;
use std::process::{Command, Output};

use serde_json::Value;
use tesserae_testutil::{DiskImage, Fixture};

fn cli(args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_tesserae-cli"))
        .args(args)
        .output()
        .expect("the CLI binary must start")
}

fn scan_json(path: &Path, extra: &[&str]) -> (i32, Value) {
    let mut args = vec!["scan", path.to_str().unwrap(), "--json"];
    args.extend_from_slice(extra);
    let out = cli(&args);
    let stdout = String::from_utf8(out.stdout).unwrap();
    let json = serde_json::from_str(&stdout)
        .unwrap_or_else(|e| panic!("stdout is not one JSON document ({e}):\n{stdout}"));
    (out.status.code().expect("killed by a signal"), json)
}

/// Bytes the filesystem says are allocated to the file at `path`.
fn allocated(path: &Path) -> u64 {
    std::fs::symlink_metadata(path).unwrap().blocks() * 512
}

/// The tree every totals test uses: four files and three directories (the
/// root counts), with sizes that make logical and allocated differ. The root
/// holds a file of its own, so its total differs from every child's.
fn small_tree() -> Fixture {
    let fx = Fixture::new().unwrap();
    fx.file("a/one.bin", 1000).unwrap();
    fx.file("a/b/two.bin", 5000).unwrap();
    fx.file("top.bin", 3000).unwrap();
    fx.file("empty.bin", 0).unwrap();
    fx
}

const SMALL_TREE_FILES: [&str; 4] = ["a/one.bin", "a/b/two.bin", "top.bin", "empty.bin"];

#[test]
fn json_totals_match_the_filesystem_and_the_exit_status_is_zero() {
    let fx = small_tree();
    let expected_allocated: u64 = SMALL_TREE_FILES
        .iter()
        .map(|f| allocated(&fx.path().join(f)))
        .sum();
    // Precondition: logical and allocated are different numbers, so a CLI
    // that printed one under the other's name would be caught. (The allocated
    // figure is read from the filesystem, not written as 4096 + 8192: APFS has
    // been seen to allocate more than a file's rounded size.)
    assert!(expected_allocated >= 4096 + 8192 + 4096);
    assert_ne!(expected_allocated, 9000);

    let (code, json) = scan_json(fx.path(), &[]);

    assert_eq!(code, 0, "{json}");
    assert_eq!(json["complete"], true);
    assert_eq!(json["dirs"], 3);
    assert_eq!(json["files"], 4);
    assert_eq!(json["logical_bytes"], 9000);
    assert_eq!(json["allocated_bytes"], expected_allocated);
    assert_eq!(json["path"], fx.path().to_str().unwrap());
    for key in ["walk_secs", "freeze_secs", "total_secs"] {
        assert!(json["elapsed"][key].as_f64().unwrap() >= 0.0, "{key}");
    }
}

#[test]
fn json_carries_every_incompleteness_field_even_when_clean() {
    let fx = small_tree();
    let (code, json) = scan_json(fx.path(), &[]);
    assert_eq!(code, 0);
    // The object is exactly the documented fields: nothing missing, nothing
    // extra, so a field dropped from the output is caught here.
    let mut keys: Vec<&str> = json
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect();
    keys.sort_unstable();
    assert_eq!(
        keys,
        [
            "allocated_bytes",
            "complete",
            "depth_capped",
            "dirs",
            "elapsed",
            "errors",
            "files",
            "hardlink_dups",
            "incomplete",
            "logical_bytes",
            "lost_entries",
            "path",
            "skipped_mounts",
            "stalled_at",
            "unreadable",
        ]
    );
    assert_eq!(json["incomplete"], Value::Null);
    assert_eq!(json["stalled_at"], Value::Null);
    assert_eq!(json["unreadable"], serde_json::json!([]));
    assert_eq!(json["skipped_mounts"], serde_json::json!([]));
    for key in ["lost_entries", "hardlink_dups", "depth_capped", "errors"] {
        assert_eq!(json[key], 0, "{key}");
    }
}

#[test]
fn a_budget_that_cuts_the_walk_short_exits_two_and_names_the_reason() {
    let fx = Fixture::new().unwrap();
    for i in 0..40 {
        fx.file(&format!("f{i:02}.bin"), 100).unwrap();
    }
    // Precondition: the tree is bigger than the budget, and unrestricted it
    // completes. Otherwise a budget of 10 would prove nothing.
    let (full_code, full) = scan_json(fx.path(), &[]);
    assert_eq!((full_code, full["files"].as_u64()), (0, Some(40)));

    let (code, json) = scan_json(fx.path(), &["--node-budget", "10"]);

    assert_eq!(code, 2, "{json}");
    assert_eq!(json["complete"], false);
    assert_eq!(json["incomplete"], "NodeBudget");
    let nodes = json["dirs"].as_u64().unwrap() + json["files"].as_u64().unwrap();
    assert!(nodes <= 10, "{nodes} nodes under a budget of 10");
}

#[test]
fn a_root_that_cannot_be_opened_exits_one_with_the_errno() {
    let fx = Fixture::new().unwrap();
    let missing = fx.path().join("missing");

    let out = cli(&["scan", missing.to_str().unwrap(), "--json"]);

    assert_eq!(out.status.code(), Some(1));
    assert!(out.stdout.is_empty(), "no result document on failure");
    let stderr = String::from_utf8(out.stderr).unwrap();
    assert!(stderr.contains("errno 2"), "ENOENT is 2: {stderr}");
    assert!(stderr.contains("missing"), "the path is named: {stderr}");
}

#[test]
fn unreadable_hardlinked_and_depth_capped_entries_reach_their_own_fields() {
    let fx = Fixture::new().unwrap();
    fx.file("deep/er/est/leaf.bin", 10).unwrap();
    fx.file("locked/inside.bin", 10).unwrap();
    fx.chmod("locked", 0o000).unwrap();
    fx.file("orig.bin", 4096).unwrap();
    fx.hardlink("orig.bin", "link1.bin").unwrap();
    fx.hardlink("orig.bin", "link2.bin").unwrap();

    let (code, json) = scan_json(fx.path(), &["--max-depth", "2"]);

    assert_eq!(code, 0, "unreadable and capped are not incomplete: {json}");
    assert_eq!(
        json["unreadable"],
        serde_json::json!([fx.path().join("locked").to_str().unwrap()])
    );
    // Two extra links to one inode. Not 1, so it cannot be confused with the
    // depth cap below.
    assert_eq!(json["hardlink_dups"], 2);
    // `deep/er` is at depth 2: recorded, not entered.
    assert_eq!(json["depth_capped"], 1);
    // The three links count the bytes once.
    assert_eq!(json["allocated_bytes"], 4096);
}

#[test]
fn a_mount_inside_the_tree_is_reported_with_its_reason() {
    let fx = Fixture::new().unwrap();
    fx.dir("mnt").unwrap();
    let mnt = fx.path().join("mnt");
    let _image = DiskImage::attach(&mnt, 16).unwrap();

    let (code, json) = scan_json(fx.path(), &[]);

    assert_eq!(code, 0, "{json}");
    assert_eq!(
        json["skipped_mounts"],
        serde_json::json!([{ "path": mnt.to_str().unwrap(), "reason": "OtherVolume" }])
    );
    // The mount point is still a directory node: the root and `mnt`.
    assert_eq!(json["dirs"], 2);
}

#[test]
fn text_output_prints_every_field_with_its_value() {
    let fx = small_tree();
    let out = cli(&["scan", fx.path().to_str().unwrap()]);
    assert_eq!(out.status.code(), Some(0));
    let text = String::from_utf8(out.stdout).unwrap();
    let fields: HashMap<&str, &str> = text
        .lines()
        .filter_map(|l| l.split_once(':'))
        .map(|(k, v)| (k.trim(), v.trim()))
        .collect();
    let value = |k: &str| {
        *fields
            .get(k)
            .unwrap_or_else(|| panic!("no {k:?} line:\n{text}"))
    };

    assert_eq!(value("dirs"), "3");
    assert_eq!(value("files"), "4");
    assert!(value("logical").starts_with("9000 bytes"), "{text}");
    let allocated: u64 = SMALL_TREE_FILES
        .iter()
        .map(|f| allocated(&fx.path().join(f)))
        .sum();
    assert!(
        value("allocated").starts_with(&format!("{allocated} bytes")),
        "{text}"
    );
    assert!(value("elapsed").ends_with(')'), "{text}");
    assert_eq!(value("incomplete"), "no");
    assert_eq!(value("stalled_at"), "-");
    for key in [
        "unreadable",
        "skipped_mounts",
        "lost_entries",
        "hardlink_dups",
        "depth_capped",
        "errors",
    ] {
        assert_eq!(value(key), "0", "{key}");
    }
}

#[test]
fn help_documents_the_exit_statuses_and_lossy_paths() {
    let out = cli(&["--help"]);
    assert_eq!(out.status.code(), Some(0));
    let help = String::from_utf8(out.stdout).unwrap();
    for needle in ["scan <path>", "--json", "lossy", "exit status"] {
        assert!(help.contains(needle), "help lacks {needle:?}:\n{help}");
    }
}

#[test]
fn bad_usage_exits_one_with_the_usage_on_stderr() {
    for args in [
        &[][..],
        &["scan"],
        &["frobnicate", "."],
        &["scan", ".", "--no-such-flag"],
        &["scan", ".", "--node-budget"],
        &["scan", ".", "--node-budget", "many"],
    ] {
        let out = cli(args);
        assert_eq!(out.status.code(), Some(1), "{args:?}");
        assert!(out.stdout.is_empty(), "{args:?}");
        let stderr = String::from_utf8(out.stderr).unwrap();
        assert!(stderr.contains("usage"), "{args:?}: {stderr}");
    }
}
