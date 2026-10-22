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
gate: no-home-paths strings-test lint test header ship-lib deny ffi app-test shipped-app release-metadata-test release-test demo-volume-test

# Reject the running user's home path in every tracked text file. Matching
# $HOME exactly (not any "/Users/") lets docs discuss macOS paths such as
# /System/Volumes/Data/Users/… while still catching a leaked home directory.
no-home-paths:
    @status=0; git grep -n -I -F -e "$HOME/" -- . || status=$?; test "$status" -eq 1

# Enforce the production UI localization boundary.
strings-test:
    python3 scripts/tests/strings_test.py

# The disk-image integration tests attach and detach real images with hdiutil.
# `setrlimit` is process-wide, so the descriptor-limit test is `#[ignore]`d in
# the suite and gets a process and a thread to itself here, as in CI.
#
# All tests, then the serialized descriptor-limit test.
test:
    cargo test --workspace --locked
    cargo test --manifest-path tools/applesauce/Cargo.toml --locked
    cargo test -p tesserae-core --lib --locked -- --ignored --exact --test-threads=1 pool::tests::raises_nofile_limit_and_falls_back_to_fewer_workers

# Formatting and clippy, for the workspace and for fuzz/ (a separate crate).
lint:
    cargo fmt --check
    cargo clippy --workspace --all-targets --locked -- -D warnings
    cargo fmt --check --manifest-path fuzz/Cargo.toml
    cargo clippy --manifest-path fuzz/Cargo.toml --all-targets --locked -- -D warnings

# Licences, including the separately configured bundled helper.
deny:
    cargo deny check licenses
    cargo deny --manifest-path fuzz/Cargo.toml check licenses
    cargo deny --manifest-path tools/applesauce/Cargo.toml --config tools/applesauce/deny.toml check licenses

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
app-test: applesauce
    cargo build -p tesserae-core --example archive_decode --locked
    rm -rf apple/build/TesseraeKit-test.xcresult
    xcodebuild test -project apple/Tesserae.xcodeproj -scheme TesseraeKit -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath apple/build/DerivedData -resultBundlePath apple/build/TesseraeKit-test.xcresult

# Build the pinned universal compression helper.
applesauce:
    scripts/build-applesauce.sh

# Unsigned universal Release build of the app, as CI builds it.
app-build: applesauce
    rm -rf apple/build/Tesserae-build.xcresult
    xcodebuild build -project apple/Tesserae.xcodeproj -scheme Tesserae -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/build/DerivedData -resultBundlePath apple/build/Tesserae-build.xcresult CODE_SIGNING_ALLOWED=NO 'SWIFT_ACTIVE_COMPILATION_CONDITIONS='

# Release-optimized diagnostics, isolated from the shipping DerivedData.
app-build-testhooks: applesauce
    rm -rf apple/build/Tesserae-testhooks-build.xcresult
    xcodebuild build -project apple/Tesserae.xcodeproj -scheme Tesserae -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/build/DerivedData-testhooks -clonedSourcePackagesDirPath apple/build/DerivedData/SourcePackages -resultBundlePath apple/build/Tesserae-testhooks-build.xcresult CODE_SIGNING_ALLOWED=NO 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) TESSERAE_TEST_HOOKS'

shipped-app: app-build app-build-testhooks
    scripts/check-shipped-app.sh
    python3 -I scripts/tests/test_hooks_test.py

# Release metadata, bundled licence and app chrome checks.
release-metadata-test: app-build
    python3 scripts/tests/icon_test.py
    python3 scripts/tests/applesauce_bundle_test.py
    python3 scripts/tests/release_metadata_test.py
    python3 scripts/tests/updates_test.py
    xcrun swiftc -parse-as-library apple/Tesserae/AppChrome.swift scripts/tests/AppChromeTests.swift -o apple/build/app-chrome-tests
    apple/build/app-chrome-tests apple/build/DerivedData/Build/Products/Release/Tesserae.app
    xcrun swiftc -parse-as-library -F apple/build/DerivedData/Build/Products/Release -framework Sparkle -Xlinker -rpath -Xlinker '@executable_path/DerivedData/Build/Products/Release' apple/Tesserae/Updates.swift apple/Tesserae/AppChrome.swift scripts/tests/UpdatesTests.swift -o apple/build/updates-tests
    apple/build/updates-tests

# FDA grants need a real code signature; if testing again, the user must toggle FDA off/on for the new signature.
fda-copy: app-build-testhooks
    test -d apple/build/DerivedData-testhooks/Build/Products/Release/Tesserae.app || { echo "Test-hook app missing; run just app-build-testhooks first." >&2; exit 1; }
    mkdir -p apple/build/fda-run
    rm -rf apple/build/fda-run/Tesserae.app
    ditto apple/build/DerivedData-testhooks/Build/Products/Release/Tesserae.app apple/build/fda-run/Tesserae.app
    for f in apple/build/fda-run/Tesserae.app/Contents/Frameworks/*.framework; do codesign --force --deep --sign - "$f"; done
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

# env expands these references itself before starting Bash; no caller shell runs.
# Local release: build and verify; --publish requires typed confirmation.
[script("/usr/bin/env", "-S", "-i PATH=${PATH} HOME=${HOME} TMPDIR=${TMPDIR} LANG=${LANG} LC_ALL=${LC_ALL} LC_COLLATE=${LC_COLLATE} LC_CTYPE=${LC_CTYPE} LC_MESSAGES=${LC_MESSAGES} LC_MONETARY=${LC_MONETARY} LC_NUMERIC=${LC_NUMERIC} LC_TIME=${LC_TIME} USER=${USER} DEVELOPER_DIR=${DEVELOPER_DIR} GH_TOKEN=${GH_TOKEN} CI=${CI} TESSERAE_TAP_DIR=${TESSERAE_TAP_DIR} NOTARY_KEYCHAIN=${NOTARY_KEYCHAIN} /bin/bash --noprofile --norc -euo pipefail")]
[positional-arguments]
release version *flags:
    /bin/bash --noprofile --norc scripts/release.sh "$@"

# Release pipeline tests use fake Apple tools and never contact Apple.
[script("/usr/bin/env", "-S", "-i PATH=${PATH} HOME=${HOME} TMPDIR=${TMPDIR} LANG=${LANG} LC_ALL=${LC_ALL} LC_COLLATE=${LC_COLLATE} LC_CTYPE=${LC_CTYPE} LC_MESSAGES=${LC_MESSAGES} LC_MONETARY=${LC_MONETARY} LC_NUMERIC=${LC_NUMERIC} LC_TIME=${LC_TIME} USER=${USER} DEVELOPER_DIR=${DEVELOPER_DIR} /bin/bash --noprofile --norc -euo pipefail")]
release-test:
    set -euo pipefail
    /bin/bash --noprofile --norc scripts/tests/release_test.sh
    python3 -I scripts/tests/publish_test.py
    python3 -I scripts/tests/release_workflow_test.py
    python3 -I scripts/tests/release_input_test.py

# Regenerate the macOS app icon and local review previews.
icon:
    xcrun swift scripts/make-icon.swift apple/Tesserae/Assets.xcassets --review apple/build/icon-review

# Run after app-build to also verify the compiled bundle icon.
icon-test:
    python3 scripts/tests/icon_test.py

# Synthetic screenshot disk. Flags must include --target and --volume-uuid.
# Preview with --dry-run --manifest apple/build/demo-manifest.tsv.
[positional-arguments]
demo-volume *flags:
    python3 -I scripts/make-demo-volume.py "$@"

demo-volume-test:
    python3 -I scripts/tests/demo_volume_test.py
    python3 -I scripts/tests/demo_snapshot_test.py

# Refresh the committed metadata-only source tree from HEAD.
demo-tesserae-snapshot:
    python3 -I scripts/demo/snapshot-tesserae-tree.py
