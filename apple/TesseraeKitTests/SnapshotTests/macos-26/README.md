# Hosted macOS 26 reference provenance

- Source: `33747ef6270e62d52ba30c265bb61e0c659ff0ca`
- CI run: https://github.com/sdelavega/tesserae/actions/runs/41733969837
- Artifact: `xcode-results`, ID `13278976556`
- Runner: `macos-26-arm64`, image `20261026.0455.2`
- Runtime: macOS 26.6.2 (25G83), pinned Xcode 26.6
- Review date: 2026-11-03

The 97 failed reference comparisons supplied diagnostic PNGs. All retained
reference dimensions matched. Reviewed all diagnostic images in contact sheets
and the main window, confirmation and partial-scan dialogs at full size. The
remaining nine references were unchanged and had already passed byte-for-byte
on this runner. No tolerances, skips or layout assertions were changed.

The hosted run passed Metal/CoreGraphics palette parity, archive verification,
fixture cleanup, bounded estimate concurrency/cancellation, and the 100ms
heartbeat check. Its only 97 failures were image reference comparisons against
the other host. This directory needs a fresh exact-comparison pass in CI before
release; reference review alone is not that pass.
