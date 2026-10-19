# Developer entry points. This file is an index: each recipe is one cargo
# command or a call to a script in scripts/, and the scripts are what CI runs
# too, so a recipe and a CI step cannot drift apart without one of them
# visibly changing.
#
# Homebrew's cargo can precede ~/.cargo/bin on PATH and ignores
# rust-toolchain.toml, so put rustup's shims first for every recipe. (The
# scripts do the same for themselves, so they are also safe to run directly.)

export PATH := env_var('HOME') + "/.cargo/bin:" + env_var('PATH')

set shell := ["bash", "-euo", "pipefail", "-c"]

# List the recipes.
default:
    @just --list

# Every check CI runs, in CI's order.
gate: lint test deny header ship-lib

# All tests, including the disk-image integration tests (they attach and
# detach real images with hdiutil).
test:
    cargo test --workspace

# Formatting and clippy, for the workspace and for fuzz/ (a separate crate).
lint:
    cargo fmt --check
    cargo clippy --workspace --all-targets -- -D warnings
    cargo fmt --check --manifest-path fuzz/Cargo.toml
    cargo clippy --manifest-path fuzz/Cargo.toml --all-targets -- -D warnings

# Licences, for the workspace and for fuzz/.
deny:
    cargo deny check licenses
    cargo deny --manifest-path fuzz/Cargo.toml check licenses

# Regenerate include/tesserae.h and fail if it differs from what is committed.
header:
    scripts/gen-header.sh
    git diff --exit-code -- crates/tesserae-ffi/include/tesserae.h

# Build the static library the app links and check it carries no test hooks.
ship-lib:
    scripts/check-shipped-lib.sh

# Criterion benchmarks (parse and freeze). Reported, not asserted.
bench:
    cargo bench -p tesserae-core

# Generate a 500,000-file disk image, time the CLI on it RUNS times, detach it.
bench-volume runs="5":
    scripts/bench-volume.sh {{runs}}

# Fuzz the buffer parser for SECONDS (needs the pinned nightly and cargo-fuzz).
fuzz seconds="60":
    scripts/fuzz-parser.sh {{seconds}}

# Scan a directory with the release CLI: `just scan ~/src --json`.
scan path *flags:
    cargo run --release -p tesserae-cli -- scan "{{path}}" {{flags}}
