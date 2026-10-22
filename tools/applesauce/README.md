# Bundled applesauce

Tesserae's separate binary crate packages the GPL-3.0-or-later CLI from
[Dr-Emann/applesauce, applesauce-cli-v0.5.30](https://github.com/Dr-Emann/applesauce/releases/tag/applesauce-cli-v0.5.30).
`src/main.rs` and `src/progress.rs` are verbatim upstream files with provenance
and GPL notices prepended. The package is named `tesserae-applesauce`; the
executable remains `applesauce`. Consequently `--version` prints
`tesserae-applesauce 0.5.30` instead of `applesauce-cli 0.5.30`.

The CLI's direct dependencies and features match upstream, with exact versions
from that tag's Cargo.lock. The applesauce library comes from crates.io.
Cargo.lock pins the complete dependency graph. This crate is excluded from the
main workspace. Its own deny.toml permits GPL-3 and its dependency licences;
the main workspace allowlist is unchanged. `just deny` audits both manifests.
Bundled licence notices and dependency texts are in
`apple/Tesserae/Licenses/applesauce-LICENSE.txt`.

Build with `just applesauce` (both macOS architectures, --locked, ad-hoc runtime
signature); `just app-build` builds it before Xcode copies and signs it.

To upgrade, choose an upstream release tag, replace both source files verbatim
while preserving the provenance/GPL prefix, and update the package version,
features and exact dependency versions from that tag's CLI manifest and lock.
Seed Cargo.lock from upstream, resolve the local crate, review any changes,
regenerate the bundled dependency licence texts, and update the tag in the
bundle test and notices. Run `just deny`, the helper tests and `just gate`.
Recheck --verify support and the scratch-volume measurements before shipping.
