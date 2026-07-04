# Snapcat v0.2 — Distribution + Sparkle auto-update (Source of Truth)

Goal: Snapcat becomes distributable to other Macs via GitHub Releases on
`beerbeatbox/snapcat` (public), with Sparkle 2 auto-update fed by an
`appcast.xml` committed to the repo's `main` branch.

Files in scope: `project.yml`, `.gitignore`, `Snapcat/Sources/AppDelegate.swift`,
new `scripts/release.sh`, README.md (add a Download/Update section), and the
generated Sparkle public key. Editor/capture/preview sources are OFF-limits.

The repo is now a git repo with a pushed `main` — do NOT commit or push
anything; leave changes in the working tree for review.

## Acceptance

1. `xcodegen generate` succeeds with the new project.yml.
2. Debug still builds: `xcodebuild -project Snapcat.xcodeproj -scheme Snapcat -configuration Debug build` exits 0.
3. Release builds AND signs locally with Developer ID:
   `xcodebuild -project Snapcat.xcodeproj -scheme Snapcat -configuration Release build` exits 0
   (the "Developer ID Application: Woraprot Dechrut (YYVT547SZ7)" identity is in
   the login keychain). Verify with `codesign -dv` on the Release .app that
   Authority is Developer ID and runtime flag is set.
4. `bash -n scripts/release.sh` passes; script is `chmod +x`.
5. A real Sparkle EdDSA public key is embedded in Info.plist properties (no
   placeholder), and the private key is exported to `sparkle_priv.pem` in the
   repo root, which MUST be gitignored BEFORE the key is created.
6. Do NOT run the app, do NOT notarize, do NOT create a GitHub release (those
   need the user's Apple credentials / a version bump decision).

## 1. project.yml changes

- Add the Sparkle package and dependency:

```yaml
packages:
  Sparkle:
    url: https://github.com/sparkle-project/Sparkle
    from: "2.6.0"
```

  and under the Snapcat target: `dependencies: [{package: Sparkle}]`.

- Release-only signing overrides (base stays Apple Development for Debug):

```yaml
    settings:
      base: (existing…)
      configs:
        Release:
          CODE_SIGN_IDENTITY: "Developer ID Application"
          ENABLE_HARDENED_RUNTIME: YES
          OTHER_CODE_SIGN_FLAGS: "--timestamp"
          DEAD_CODE_STRIPPING: YES
```

- Info.plist properties additions:
  - `SUFeedURL`: `https://raw.githubusercontent.com/beerbeatbox/snapcat/main/appcast.xml`
  - `SUPublicEDKey`: the real key from step 3
  - `SUEnableAutomaticChecks`: true
  - `LSApplicationCategoryType`: `public.app-category.utilities`

## 2. AppDelegate — Check for Updates menu

- `import Sparkle`.
- Stored property:
  `private let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)`
- Menu: after "Edit Last Capture" add a separator and
  "Check for Updates…" with `target = updaterController`,
  `action = #selector(SPUStandardUpdaterController.checkForUpdates(_:))`.
  (Sparkle handles enable/disable via menu validation itself.)
- The app is LSUIElement; Sparkle's update window activates the app itself —
  no extra activation code needed.

## 3. Sparkle keys + CLI tools

- FIRST add to `.gitignore`: `sparkle_priv.pem`, `tools/`.
- Download the latest Sparkle distribution archive (it ships the CLI tools that
  the SPM package does not expose conveniently):
  `gh release download -R sparkle-project/Sparkle -p 'Sparkle-2*.tar.xz' -D tools/ && tar -xf tools/Sparkle-2*.tar.xz -C tools/`
  → tools land in `tools/bin/` (generate_keys, sign_update, generate_appcast).
- `./tools/bin/generate_keys` — generates an EdDSA pair, private key goes into
  the login Keychain, prints the public key. Then export a file copy for
  future CI: `./tools/bin/generate_keys -x sparkle_priv.pem`.
- Put the printed public key into project.yml's `SUPublicEDKey`, regenerate,
  rebuild.
- If the keychain path fails in this non-interactive shell, fall back to
  file-based generation if the tool supports it, and note the deviation.

## 4. scripts/release.sh

`./scripts/release.sh <version>` (e.g. `0.2.0`). Steps, failing fast with a
clear message at each:

1. Preflight: clean git tree required; `xcrun notarytool history --keychain-profile snapcat-notary`
   must succeed — else print the one-time setup command and exit:
   `xcrun notarytool store-credentials snapcat-notary --apple-id <APPLE_ID> --team-id YYVT547SZ7 --password <app-specific password>`.
2. Bump versions in project.yml: `MARKETING_VERSION` → `<version>`,
   `CURRENT_PROJECT_VERSION` → previous value + 1 (sed in place; these keys
   must exist in project.yml — add MARKETING_VERSION/CURRENT_PROJECT_VERSION
   to base settings if not already there).
3. `xcodegen generate` + Release build into `build/dd` (derivedDataPath).
4. `APP=build/dd/Build/Products/Release/Snapcat.app`; `codesign --verify --deep --strict "$APP"`.
5. Zip for notarization: `ditto -c -k --keepParent "$APP" build/dist/Snapcat-<v>.zip`.
6. Notarize + staple:
   `xcrun notarytool submit build/dist/Snapcat-<v>.zip --keychain-profile snapcat-notary --wait`,
   then `xcrun stapler staple "$APP"`, then REBUILD the zip from the stapled
   app (same ditto command, overwrite) — the stapled ticket must be inside the
   distributed zip.
7. DMG: stage the stapled app + an `/Applications` symlink in a temp dir,
   `hdiutil create -volname Snapcat -srcfolder <stage> -ov -format UDZO build/dist/Snapcat-<v>.dmg`,
   notarize the DMG the same way, `stapler staple` it.
8. Appcast: `mkdir -p build/appcast && cp build/dist/Snapcat-<v>.zip build/appcast/`,
   `./tools/bin/generate_appcast --download-url-prefix "https://github.com/beerbeatbox/snapcat/releases/download/v<v>/" -o appcast.xml build/appcast/`
   (uses the Keychain EdDSA key automatically; falls back to `--ed-key-file sparkle_priv.pem` if needed).
9. `gh release create v<v> build/dist/Snapcat-<v>.zip build/dist/Snapcat-<v>.dmg --title "Snapcat <v>" --generate-notes`.
10. `git add project.yml appcast.xml && git commit -m "Release v<v>" && git push`.
11. Echo a summary: release URL + reminder that running apps will see the
    update within a day (or via Check for Updates…).

The script must be re-runnable: `set -euo pipefail`, guard each artifact dir
with `mkdir -p`, `-ov`/`--clobber` style flags where applicable.

## 5. README.md

Add (Thai, matching existing tone): a Download section (link to
`https://github.com/beerbeatbox/snapcat/releases/latest`, "open the DMG, drag
to Applications"), first-run permissions note already exists, and an Updates
section (auto-check daily + Check for Updates… in the menu). Also a Release
section for the maintainer: the one-time notarytool store-credentials command
and `./scripts/release.sh <version>`.

## Pitfalls

- Gitignore `sparkle_priv.pem` + `tools/` BEFORE generating/downloading.
- Staple BEFORE re-zipping; the notarized-but-unstapled first zip is only for
  the notary submission.
- `generate_appcast` needs the zip filename to match what the GitHub release
  asset will be called — keep `Snapcat-<v>.zip` consistent between steps.
- SUFeedURL uses raw.githubusercontent.com on main — the appcast commit/push
  (step 10) is what actually publishes the update to users.
- Sparkle compares `CFBundleVersion` (CURRENT_PROJECT_VERSION) — it must
  strictly increase every release; the marketing version is display-only.
- Don't touch the TCC-relevant bundle id — it stays `com.beer.snapcat`.

Report: per-file changes, the generated public key, tool/deviation notes, and
the three acceptance build results.
