# Releasing Tesserae

Publishing is confirmed separately for every release. A local build publishes
nothing until you request `--publish` and type the exact version at its prompt.
For CI, a maintainer's deliberate push of `vX.Y.Z` confirms that release; there
is no general `--yes` switch. The tag workflow explicitly skips private repos.
Do not enable or trigger it as part of setup or syntax validation.

## Local releases

Use a clean `main` checkout matching `origin/main`, the pinned Rust toolchain,
Xcode with the Metal toolchain, and the tools used by `just gate` (`just`,
`cargo-deny`, cbindgen 0.29.4). Install GitHub CLI and authenticate it for this
repository; the publishing checks use `curl` and, when installed, `brew`.
The release version must equal every `MARKETING_VERSION` in the Xcode project.
Commit release notes at `docs/releases/X.Y.Z.md` before building. The bundle
version is derived as `major * 10000 + minor * 100 + patch`; use a new version
for each release.

One-time setup, performed by the maintainer on their Mac:

1. Install the Developer ID Application certificate and its private key in
   the login keychain. Copy `apple/Release.local.xcconfig.example` to
   `apple/Release.local.xcconfig` and fill in `DEVELOPMENT_TEAM`, the
   certificate’s 40-hex SHA-1
   `CODE_SIGN_IDENTITY`, and `NOTARY_PROFILE = notarytool`. A full
   `Developer ID Application: … (TEAMID)` name is accepted only when it resolves
   uniquely; use the hash when two certificates share a name. Preflight resolves
   the hash, checks the Developer ID Application name and team, and pins that
   same hash for archive, export and DMG signing. The local file is ignored;
   never commit it.
2. Store notarization credentials yourself, using the same profile name:

   ```sh
   xcrun notarytool store-credentials notarytool
   ```

   Follow its prompts for your Apple ID, team ID and an app-specific password.
   Set `NOTARY_PROFILE = notarytool` in the local configuration. The
   interactive command avoids putting the password in shell history.
3. The Sparkle key must already be in your login keychain. Local
   `generate_appcast` and the final `sign_update` feed-signing pass use that same key directly. Use the existing key matching
   the committed `SUPublicEDKey`; do not generate a replacement for a release.
4. Clone `sdelavega/homebrew-tap` to, for example, `~/src/homebrew-tap`, with
   push access, and set:

   ```sh
   export TESSERAE_TAP_DIR=~/src/homebrew-tap
   ```

Build and verify without publishing:

```sh
just release X.Y.Z
```

Build, verify and then review the displayed tag, DMG checksum, appcast diff and
cask diff; type the exact version when prompted to publish:

```sh
just release X.Y.Z --publish
```

The script runs the full gate, archives and exports a universal Developer ID
app, verifies the team, hardened runtime and secure timestamp of every nested
framework, XPC service and helper app, then signs and notarizes the DMG,
staples it, validates it and assesses both the DMG and mounted app with
Gatekeeper. It creates and verifies the signed
appcast using the pinned Sparkle tools. Generation uses a fresh temporary
directory containing only this run’s verified DMG, notes and the published
appcast freshly fetched from `origin/gh-pages`; stale `dist/` archives cannot
enter the feed. Deltas are disabled and all historical versions are retained.
The result must add exactly one item for the new version and leave every
previous item and the published document unchanged. Serializer indentation
is normalized by inserting only the validated new item into the original
feed bytes; altered historical content or metadata is refused. The changing Sparkle
signature footer is excluded from history comparisons. `SUVerifyUpdateBeforeExtraction`
and `SURequireSignedFeed` are enabled in the app. Sparkle 2.10 `generate_appcast`
signs feeds when an included app requires it; after the history merge, `sign_update`
re-signs the final XML with the same EdDSA key. Verification checks both the DMG
signature and the embedded feed signature against the committed public key.
An unsigned feed or any edit after signing prevents verification and publishing. Every publish
entry point fetches and checks the whole feed again before showing the diff.
Only after verification succeeds does it write `dist/MANIFEST`: JSON fields `version`, `commit`, `dmg_sha256` and
`verified_at` (UTC). `dist/SHA256SUMS` and the release log are retained locally.

Every publish entry point requires that manifest to match the requested
version, HEAD, any existing version tag, and the DMG bytes. It validates the
staple and reassesses the DMG before publishing. A bare
`scripts/publish.sh X.Y.Z` is refused. After a partial publish, use the printed
resume command with the same verified artifacts and commit:

```sh
scripts/publish.sh X.Y.Z --resume
```

Resume requires the version tag on origin to match HEAD and still asks for the
exact version. It can re-upload assets and finish Pages and tap updates. Pages
uses a detached worktree without creating local release-feed branches. The
confirmation diff uses a fresh origin snapshot, and history is checked again
before the Pages commit. After pushing, Pages fetches retry on HTTP errors
and stale bytes with 5/10/20-second capped backoff: at most 25 requests of
5 seconds each (under ten minutes total). Exhaustion fails with the resume
command; the release assets and tap may already have been published. Keep
the tap clean; resume accepts only an exact staged cask from the interrupted
release. Never repair an artifact by editing its manifest.

## Tag workflow (inactive while private)

`.github/workflows/release.yml` listens only to pushed `v*` tags. Its one job
requires a public repository and runs on `macos-26`, explicitly selecting
Xcode 26.6 and downloading MetalToolchain if necessary. It fetches full Git
history and uses the pinned Rust targets and gate tools. `release.sh` runs
`just gate` and `just ffi` before archiving.

Before the first CI release, the maintainer must separately make the intended
repositories public, configure GitHub Pages to serve the `gh-pages` branch,
and provision the secrets and variables below. No setup action itself
confirms a release. Do not push a version tag until you intend to publish it.
The workflow uses `contents: write` for the release repository; the tap needs
its own token. Repository settings or organization policy must permit those
writes.

Create repository Actions secrets in GitHub Settings → Secrets and variables
→ Actions → Secrets. Perform certificate and private-key handling yourself on
a trusted Mac, outside agent sessions, recordings and logs. Never commit
credentials or paste them into an issue, command argument, or chat.

| Secret | Meaning and creation |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | In Keychain Access → My Certificates, select the Developer ID **Application** identity including its private key and export it as a password-protected `.p12`, for example `~/developer-id.p12`. Encode its bytes with `base64 -i ~/developer-id.p12 \| pbcopy`, then paste the clipboard into this secret. Remove the temporary export and clear the clipboard afterwards. A certificate without its private key cannot sign. |
| `DEVELOPER_ID_P12_PASSWORD` | The export password you chose for that `.p12`; store it as a separate secret. |
| `NOTARY_API_KEY_P8` | The contents of an App Store Connect team API private key (`.p8`) authorized for notarization. The maintainer creates and stores this outside agent sessions. CI writes it with mode 0600 under `$RUNNER_TEMP`, stores the `tesserae-ci` notary profile, and removes it immediately; `always()` cleanup also removes it on failure. |
| `SPARKLE_ED_PRIVATE_KEY` | The base64 private key matching the app's existing `SUPublicEDKey`. In Keychain Access, the existing “Private key for signing Sparkle updates” item's password is this value (confirmed in pinned Sparkle's `generate_keys` source). The maintainer can reveal it locally, copy it directly into this secret, then clear the clipboard. Do not generate a new key or give an agent access to the private key. |
| `TAP_PUSH_TOKEN` | Create a fine-grained GitHub personal access token owned by an account with access to `sdelavega/homebrew-tap`; restrict repository access to that tap and grant Contents read/write. Set an expiry and arrange rotation. The workflow's second checkout persists its credentials only for that clone and removes them in checkout's post-job cleanup. |

GitHub Actions supplies `GITHUB_TOKEN` automatically for each job; do not
create a personal token for this name. It is passed as `GH_TOKEN` to
publishing, with the workflow's Contents write permission.

Set these repository Actions **variables** on the Variables tab:

| Variable | Value |
| --- | --- |
| `CODE_SIGN_IDENTITY` | The 40-hex SHA-1 of the imported Developer ID Application certificate; an unambiguous full name also works. |
| `DEVELOPMENT_TEAM` | Required signing team matching the imported certificate. |
| `NOTARY_KEY_ID` | The App Store Connect API key ID. |
| `NOTARY_ISSUER_ID` | The issuer UUID of the App Store Connect team API key. |

Local notarization uses the existing `notarytool` keychain profile and
interactive maintainer setup above. CI uses the App Store Connect API key
instead of an Apple ID password. Each provisioning command runs with only
`PATH`, `HOME`, `TMPDIR`, `LANG`, `LC_*`, `USER` and `DEVELOPER_DIR`.
Passwords are absent from command arguments except two documented residuals
on the ephemeral runner: `security` requires the random, single-use keychain
password in argv, and `security import` requires the `.p12` import password
in argv because it offers no alternative input channel. GitHub masks these
values; do not enable tracing or capture process arguments.

The workflow creates a temporary keychain with that random, masked password.
The decoded `.p12` has private permissions under `$RUNNER_TEMP` and is deleted
immediately after import. The notary profile `tesserae-ci` is stored in that
keychain, and `NOTARY_KEYCHAIN` makes each release-script notary call read it
explicitly. The local config is written from the variables without logging
its values. The Sparkle secret goes to `release.sh` through stdin, is consumed
up front into a non-exported shell variable, and reaches
both `generate_appcast --ed-key-file -` and the final
`sign_update --ed-key-file -` through private here-strings. It is unset after the
last signing pass. Other tools see EOF
on stdin; the key is never written to a key file. Child
tools receive the same environment allowlist, with `GH_TOKEN` added only for
authenticated `gh` commands. Certificate exports such as
`DEVELOPER_ID_P12_BASE64` and arbitrary unknown variables are excluded.
Credential values, including that export, are redacted from release logs.
The publish step explicitly configures the `github-actions[bot]` noreply Git
identity for both Pages and tap commits.

The tap is checked out under ignored `apple/build/release-tap` and supplied via
`TESSERAE_TAP_DIR`. CI invokes `scripts/release.sh "${GITHUB_REF_NAME#v}"
--ci-publish`. That mode requires `CI=true`, the tag on origin, and HEAD equal
to the tag; it replaces only the typed confirmation. Manifest and Apple
verification checks still apply.

The final `always()` step deletes the temporary keychain, restores the prior
keychain search list (including paths with spaces), and removes the `.p8`,
decoded files and the generated local config. Failed jobs upload Xcode result bundles and
build logs for diagnosis. Never enable shell tracing or dump the environment.
The real signing/notarization/publication path must be exercised by the
maintainer at the first authorized public release; fake-tool tests and YAML
validation cannot establish service credentials, permissions or runner-image
availability.
