# Exact snapshot references

These tests compare decoded sRGB RGBA bytes and image dimensions exactly.

The root PNGs are the reviewed macOS 27.2 host references. `macos-26/` holds
independent references for the pinned Apple Silicon CI image (macOS 26.6.2,
Xcode 26.6). Native SwiftUI/AppKit rasterization differs between these systems.
`nativeSnapshotReference` selects the macOS 26 directory only on that major
version. It does not add a tolerance or fall back when a reference is missing.
Metal/CoreGraphics agreement and all semantic/layout assertions stay separate.

When a runner image changes, inspect its actual PNG diagnostics and compare
with the existing references before updating this directory. CI retains PNGs
with its failed Xcode results. Do not accept images by enabling recording in a
normal CI or release gate. Local explicit recording uses
`TESSERAE_RECORD_SNAPSHOTS=1`; optional named recording uses
`TESSERAE_RECORD_SNAPSHOT_NAMES`. Review any recorded image before committing.

Native window captures also depend on the reference host's display/backing
configuration. These are host references, not portable rasterization claims.
See `macos-26/README.md` for the hosted reference provenance.
