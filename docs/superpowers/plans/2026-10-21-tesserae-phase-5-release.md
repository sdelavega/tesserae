# Tesserae Phase 5: Build, Sign, Notarize, Update, Tap — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Developer-ID-signed, notarized, stapled DMG of Tesserae installs cleanly. Sparkle updates it in place from an EdDSA-signed appcast. A personal Homebrew tap installs it too. Everything is produced by one local `just release` run on the user's Mac.

**Architecture:**
- **Release script:** `scripts/release.sh`, behind `just release`, runs the whole pipeline on the user's Mac:
  - universal Rust library;
  - `xcodebuild archive` and `-exportArchive` with Developer ID;
  - a DMG, then sign, notarize, staple and verify;
  - `generate_appcast`.
  - Publishing (the appcast on `gh-pages`, the GitHub Release, the tap cask) is a separate, explicitly confirmed `--publish` step.
- **Sparkle 2:** added through Swift Package Manager. The private EdDSA key stays in the user's login keychain; only the public key enters the repo.
- **CI:** the tag workflow of spec §14 is written now and runs once the repo is public.
- **Going public:** a user-gated task. It includes the history decision, because three commits on `main` contain a home path.

**Tech Stack:** Xcode 27.2 / `xcodebuild`, `notarytool`, `stapler`, `hdiutil`, Sparkle 2.x (MIT) via SPM, `gh` CLI, GitHub Pages, Homebrew tap. No other new dependencies.

**Spec:** `docs/superpowers/specs/2026-10-18-tesserae-design.md`. The sections this plan draws on:
- §14, Build and distribution: signing, entitlements, Sparkle and the privacy claim, Homebrew, licence mechanics, donations, CI.
- §2: release scope and the no-nag rule.
- §17: the Phase 5 gate, "A notarized DMG installs and updates cleanly".

## Global Constraints

- **Earlier phases' constraints still hold:**
  - Everything in the Phase 2–4 plans' Global Constraints.
  - macOS 13 APIs only in TesseraeKit; `ObservableObject`.
  - The GPL notice on every new file, with `Copyright (C) 2026 Stephen de la Vega`.
  - `project.pbxproj` is hand-edited.
  - TDD where there is logic; mutation-verified tests; never weaken an assertion.
  - Read SDK and tool facts from headers, `--help` and man pages, never memory.
  - Never `git add -f` scratch.
  - `just no-home-paths` stays green.
- **Secrets never enter the repo, a log, a commit message or an agent's output:**
  - the Developer ID certificate or its password;
  - notarytool credentials, which the user stores with `xcrun notarytool store-credentials`;
  - the Sparkle private key, which stays in the login keychain via `generate_keys`;
  - GitHub tokens.

  Agents never type passwords and never export a key.
- **Signing identity and team ID come from an untracked local file** (`apple/Release.local.xcconfig`, git-ignored, with a committed `.example`). Nothing personal is hard-coded.
- **Publishing is outward-facing** and only runs when the user confirms that specific action:
  - pushing `gh-pages`;
  - creating a GitHub Release;
  - pushing the tap repo;
  - making a repo public.

  `just release` without `--publish` builds and verifies everything locally and publishes nothing.
- **The privacy claim is exact** (spec §14): "No telemetry. The only network traffic is the update check." Sparkle is the app's only network client, and a test enforces it. Update checks are toggleable, and first launch says what is sent.
- **No nag** (spec §14): "Support Tesserae" is a single menu item. No modal, nothing on launch.
- **Licences ship in the bundle:** GPL-3 for Tesserae, MIT for Sparkle.

## Review Focus

1. **A release built from a dirty tree or a stale Rust library.** Expected: `just release` refuses (`git status` clean, tag matches `MARKETING_VERSION`, `verify-ffi-fresh` passes). Test: Task 3 `release_refuses_dirty_tree_and_version_mismatch`.
2. **Notarization rejected, or stapling skipped.** Expected: the script stops with Apple's log URL. A DMG is never published unless `stapler validate` and `spctl --assess --type open --context context:primary-signature` pass. Test: Task 3 `release_never_publishes_an_unverified_dmg` (fake tool seams).
3. **An appcast entry signed with the wrong key, or pointing at the wrong file.** Expected: the script verifies each new item's `sparkle:edSignature` with `sign_update --verify` against the committed public key, and checks the enclosure URL, length and version before publishing. Test: Task 4 `appcast_entry_matches_dmg_and_public_key`.
4. **A network connection other than Sparkle's.** Expected: none. Test: Task 2 `only_sparkle_touches_the_network`, a source scan for URLSession, NSURLConnection, Network.framework and sockets outside Sparkle.
5. **A home path or secret in published history or artifacts.** Expected: the go-public task blocks until history and artifacts are clean. Test: Task 6's checklist, `just no-home-paths` over every commit to be published, and a secret scan over the DMG, appcast and tap.

---

### Task 1: Release metadata and app chrome

**Files:**
- Modify: `apple/Tesserae.xcodeproj/project.pbxproj` (Release signing settings via an included xcconfig), `apple/Tesserae/Info.plist`, `apple/Tesserae/TesseraeApp.swift`.
- Create: `apple/Release.xcconfig`, `apple/Release.local.xcconfig.example`, `.gitignore` entry, `.github/FUNDING.yml`, `README.md`, `apple/Tesserae/Licenses/` (GPL-3 text plus the Sparkle licence, added in Task 2).

**What to build:**
- **Release signing:**
  - The Release configuration of the app and framework includes `Release.xcconfig`, which `#include?`s `Release.local.xcconfig`. That local file sets `DEVELOPMENT_TEAM` and `CODE_SIGN_IDENTITY = Developer ID Application`.
  - `CODE_SIGN_STYLE = Manual`, `ENABLE_HARDENED_RUNTIME = YES`, `--timestamp` via `OTHER_CODE_SIGN_FLAGS`.
  - Debug and test builds keep their ad-hoc and unsigned behaviour unchanged.
- **Versions:** `MARKETING_VERSION` stays the single source; `CURRENT_PROJECT_VERSION` becomes a monotonically increasing integer the release script bumps. Add a test that `CFBundleShortVersionString` and `CFBundleVersion` are populated in the built app.
- **App chrome:**
  - A "Support Tesserae" item in the Help menu opens the GitHub Sponsors URL from `FUNDING.yml`.
  - An About panel shows the version, the GPL notice and the bundled licences.
  - No launch-time UI.
- **README** carries:
  - what Tesserae is;
  - install via the DMG or `brew install --cask sdelavega/tap/tesserae`;
  - Full Disk Access, and why;
  - the exact privacy sentence;
  - the $99/yr Developer Program note from spec §14;
  - GPL-3 and how to build.
- **Tests:**
  - the menu item exists and isn't shown at launch;
  - a source scan finds no launch-time donation UI;
  - Info.plist keys and versions are present.
- [ ] Implement, test, commit `feat(app): release metadata, About, Support menu`.

### Task 2: Sparkle updates

**Files:**
- Modify: `project.pbxproj` (an `XCRemoteSwiftPackageReference` to `https://github.com/sparkle-project/Sparkle`, `upToNextMinor` from the latest 2.x release, recorded with its tag and SHA), `Info.plist` (`SUFeedURL = https://sdelavega.github.io/tesserae/appcast.xml`, `SUPublicEDKey`, `SUEnableAutomaticChecks` default true after first-launch consent), `TesseraeApp.swift`.
- Create: `apple/Tesserae/Updates.swift`, tests.

**What to build:**
- **Updater:** an `SPUStandardUpdaterController` owned by the app, plus a "Check for Updates…" menu item.
- **Settings:** a toggle "Check for updates automatically" that maps to `automaticallyChecksForUpdates`.
- **Disclosure:** first launch shows a one-line note in the onboarding or About area, with no modal: "Tesserae checks for updates once a day; the request includes the app and macOS version. You can turn this off." Spec §14 says first-launch disclosure states what is sent.
- **Signing key (coordinator step):** run Sparkle's `generate_keys` from the resolved package's `bin/` on the user's Mac. It stores the private key in the login keychain and prints the public key, which goes into `SUPublicEDKey`. The script reads the public key with `generate_keys -p`. Agents never run `generate_keys -x`, which would export the private key.
- **Licence:** Sparkle's `LICENSE` is copied into `Licenses/` and shown in About.
- **Tests:**
  - `only_sparkle_touches_the_network` (Review Focus 4): a source scan of `apple/` excluding SPM checkouts, for URLSession, NSURLConnection, `import Network`, `CFSocket` and `socket(`.
  - `SUPublicEDKey` and `SUFeedURL` are present and well-formed (base64, 32 bytes decoded; https).
  - The toggle round-trips to the updater.
- [ ] Implement, test, commit `feat(app): Sparkle updates with EdDSA-signed appcast`.

### Task 3: `just release` — build, sign, notarize, verify

**Files:**
- Create: `scripts/release.sh`, `scripts/make-dmg.sh`, `scripts/tests/release_test.sh` (bash tests with fake `xcodebuild`, `notarytool`, `stapler`, `spctl`, `codesign` on PATH).
- Modify: `justfile` (`release VERSION [--publish]`).

**Pipeline, in order; any failure stops it:**
1. **Preflight:**
   - the tree is clean;
   - on `main`, and up to date with `origin/main`;
   - `VERSION` equals `MARKETING_VERSION`;
   - the tag `vVERSION` doesn't exist yet;
   - `Release.local.xcconfig` exists;
   - the named identity is in `security find-identity -v -p codesigning`;
   - the notarytool keychain profile named in the local config exists (`notarytool history --keychain-profile …` succeeds).
2. **Gate:** `just gate`, then `just ffi`.
3. **Build:**
   - `xcodebuild archive` (Release, universal);
   - `-exportArchive` with an `ExportOptions.plist` (method `developer-id`, signingStyle manual, teamID from the local config).
4. **Verify the app:**
   - `codesign --verify --deep --strict`;
   - `codesign -d --entitlements :-` shows no sandbox;
   - the hardened-runtime flag is present;
   - the TesseraeKit and Sparkle frameworks are signed by the same team.
5. **DMG:** `make-dmg.sh` builds a UDZO DMG with the app and an `/Applications` symlink, then `codesign --timestamp` signs the DMG.
6. **Notarize:**
   - `notarytool submit --keychain-profile <profile> --wait`. On `Invalid`, run `notarytool log` and stop.
   - `stapler staple` the DMG, then `stapler validate`.
7. **Final check:**
   - `spctl --assess --type open --context context:primary-signature` on the DMG;
   - mount it read-only;
   - `spctl --assess --type execute` on the app inside;
   - detach.
8. **Artifacts:** write `dist/Tesserae-VERSION.dmg`, `dist/SHA256SUMS` and a build log with no secrets. `dist/` is git-ignored.

- **Tests (fake tools):**
  - `release_refuses_dirty_tree_and_version_mismatch`;
  - `release_never_publishes_an_unverified_dmg`: notarization "Invalid", staple failure and spctl failure each stop it before Task 4;
  - the script never echoes secret-bearing env vars.
- [ ] Implement, test, commit `feat(release): local build, sign, notarize and verify`.

### Task 4: Appcast and publishing (`just release VERSION --publish`)

**Files:**
- Modify: `scripts/release.sh`.
- Create: `scripts/publish.sh`, `scripts/appcast-check.sh`, `packaging/tesserae.rb.template` (the cask), tests.

**After Task 3 succeeds, in order:**
1. **Appcast:**
   - `generate_appcast` over `dist/` with the keychain key;
   - `appcast-check.sh` verifies the new item: version, short version, enclosure URL `https://github.com/sdelavega/tesserae/releases/download/vVERSION/Tesserae-VERSION.dmg`, length equal to the DMG size, and `sign_update --verify` against the committed `SUPublicEDKey`;
   - release notes come from `docs/releases/VERSION.md`, which the script requires to exist.
2. **Confirm:** print a summary (tag, DMG SHA-256, appcast diff, cask diff) and require typing the version to confirm. A `--yes` flag is not provided.
3. **Publish:**
   - `git tag -s vVERSION` (or `-a` if no signing key) and push the tag;
   - `gh release create` with the DMG, `SHA256SUMS` and the notes;
   - commit the appcast to the `gh-pages` branch from a separate worktree and push;
   - render the cask (version, sha256, `auto_updates true`, `depends_on macos: ">= :ventura"`, zap stanza limited to `~/Library/Application Support/Tesserae` and the app's preferences) into the local clone of `sdelavega/homebrew-tap` and push.
4. **Verify:** fetch the published appcast URL and the release asset, compare their checksums with `dist/`, and run `brew fetch --cask sdelavega/tap/tesserae`.

- **Tests (fake gh, git remote in a temp dir):**
  - `appcast_entry_matches_dmg_and_public_key`;
  - the confirmation must match the version exactly;
  - a failure after the tag push leaves a printed resume command and no partial cask.
- [ ] Implement, test, commit `feat(release): appcast, GitHub Release and tap publishing`.

### Task 5: CI tag workflow (ready for when the repo is public)

**Files:** `.github/workflows/release.yml`; document the secrets in `docs/releasing.md`.

- **The workflow, on tag `v*`, spec §14:**
  - Import the `.p12` from the `DEVELOPER_ID_P12_BASE64` / `DEVELOPER_ID_P12_PASSWORD` secrets into a temporary keychain: create, unlock, set the key partition list, add to the search list, and always delete it in a final step.
  - Store notarytool credentials from `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID` and `NOTARY_PASSWORD` into a temporary profile.
  - Feed the Sparkle key from `SPARKLE_ED_PRIVATE_KEY` through `generate_appcast --ed-key-file -` on stdin, never written to disk.
  - Run `scripts/release.sh VERSION` with `--ci-publish`. In CI that replaces the interactive confirmation with "the tag already exists and was pushed by a maintainer".
- **Not run now.** Validate the syntax with `actionlint` if it's installed, otherwise by reading. `docs/releasing.md` documents both paths.
- [ ] Commit `ci: tag release workflow (inactive while private)`.

### Task 6: Going public (needs the user; every step confirmed)

- [ ] **Privacy sweep over everything to be published:**
  - Run `just no-home-paths` on every commit of `main`: `git log -p` scanned for `$HOME/` and for the user's account name in paths.
  - Scan for secrets: private-key headers, `.p12`, base64 runs longer than 40 characters in config, `notarytool` passwords.
  - Check author emails are the noreply address.
  - Known today: commits 69436e3 (Phase 1 benchmarks), 0d82881 (Phase 2) and d6075f5 (Phase 3) contain a home path in content that later commits removed.
- [ ] **History decision (user):**
  - (a) rewrite `main` with `git filter-repo --replace-text` (home path → `~`), then force-push; or
  - (b) publish a fresh repository whose first commit is today's tree, keeping the private repo as the archive.

  Both are irreversible for anyone who has cloned. The user chooses, and the coordinator executes only that choice.
- [ ] **Make the repos public:**
  - set `sdelavega/tesserae` public;
  - create the public `sdelavega/homebrew-tap`;
  - enable Pages on `gh-pages`;
  - confirm CI runs.
- [ ] **First release:** `just release 0.1.0 --publish`.

### Task 7: Phase 5 gate

- [ ] **Install:** on this Mac, as a fresh install, download the DMG from the GitHub Release in a browser so it carries the quarantine attribute. Open it, drag to Applications, launch. Expect:
  - no Gatekeeper warning beyond the standard "downloaded from the internet" prompt;
  - `spctl -a -vv` reports "accepted, source=Notarized Developer ID".
- [ ] **Brew:** `brew install --cask sdelavega/tap/tesserae` installs the same build.
- [ ] **Update:** build and publish 0.1.1 (a one-line change with release notes). In the installed 0.1.0, "Check for Updates…" finds 0.1.1, installs it and relaunches, and the version shows 0.1.1. Full Disk Access survives the update, because the code requirement is unchanged under the same Developer ID.
- [ ] **Record:** write the results in `docs/benchmarks.md` (release section) and spec §14. Commit `docs: Phase 5 gate`.

## Not in this plan

- homebrew-cask main repository submission (it has notability thresholds; spec §14).
- Nightly Miri/ASAN CI (spec §14 lists it under CI; it lands when CI minutes exist, with Task 5's workflow).
- The 1.x items in spec §2.
