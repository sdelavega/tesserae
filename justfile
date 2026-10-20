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
gate: no-home-paths lint test header ship-lib deny ffi app-test

# Reject personal home paths in every tracked text file (including this recipe).
# Split the pattern literal so the check does not match its own definition.
no-home-paths:
    @status=0; git grep -n -I -e '/''Users/' -- . || status=$?; test "$status" -eq 1

# The disk-image integration tests attach and detach real images with hdiutil.
# `setrlimit` is process-wide, so the descriptor-limit test is `#[ignore]`d in
# the suite and gets a process and a thread to itself here, as in CI.
#
# All tests, then the serialized descriptor-limit test.
test:
    cargo test --workspace --locked
    cargo test -p tesserae-core --lib --locked -- --ignored --exact --test-threads=1 pool::tests::raises_nofile_limit_and_falls_back_to_fewer_workers

# Formatting and clippy, for the workspace and for fuzz/ (a separate crate).
lint:
    cargo fmt --check
    cargo clippy --workspace --all-targets --locked -- -D warnings
    cargo fmt --check --manifest-path fuzz/Cargo.toml
    cargo clippy --manifest-path fuzz/Cargo.toml --all-targets --locked -- -D warnings

# Licences, for the workspace and for fuzz/.
deny:
    cargo deny check licenses
    cargo deny --manifest-path fuzz/Cargo.toml check licenses

# Regenerate crates/tesserae-ffi/include/tesserae.h and fail if it differs from what is committed.
header:
    scripts/gen-header.sh
    git diff --exit-code -- crates/tesserae-ffi/include/tesserae.h

# Build the static library the app links and check it carries no test hooks.
ship-lib:
    scripts/check-shipped-lib.sh

# Xcode never runs cargo; its Run Script phase only checks the library is
# newer than the Rust sources, and fails the build telling you to run this.
#
# Build apple/build/libtesserae.a (universal) for the Xcode project to link.
ffi:
    scripts/build-ffi.sh

# TesseraeKit's XCTest suite (Debug, this machine's architecture). The result
# bundle (xcodebuild refuses to overwrite one) is what CI uploads on failure.
app-test:
    rm -rf apple/build/TesseraeKit-test.xcresult
    xcodebuild test -project apple/Tesserae.xcodeproj -scheme TesseraeKit -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath apple/build/DerivedData -resultBundlePath apple/build/TesseraeKit-test.xcresult

# Unsigned universal Release build of the app, as CI builds it.
app-build:
    rm -rf apple/build/Tesserae-build.xcresult
    xcodebuild build -project apple/Tesserae.xcodeproj -scheme Tesserae -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/build/DerivedData -resultBundlePath apple/build/Tesserae-build.xcresult CODE_SIGNING_ALLOWED=NO

# FDA grants need a real code signature; if testing again, the user must toggle FDA off/on for the new signature.
fda-copy:
    test -d apple/build/DerivedData/Build/Products/Release/Tesserae.app || { echo "Release app missing; run just app-build first." >&2; exit 1; }
    mkdir -p apple/build/fda-run
    rm -rf apple/build/fda-run/Tesserae.app
    ditto apple/build/DerivedData/Build/Products/Release/Tesserae.app apple/build/fda-run/Tesserae.app
    codesign --force --sign - apple/build/fda-run/Tesserae.app/Contents/Frameworks/TesseraeKit.framework
    codesign --force --sign - --identifier com.sdelavega.Tesserae apple/build/fda-run/Tesserae.app
    codesign --verify --deep --strict apple/build/fda-run/Tesserae.app

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
