---
name: release-bucket-list
description: "Release the Bucket List macOS app (Cloudflare R2 client) to GitHub using the bucketlist-release CLI tool. Use this skill whenever the user wants to publish a new version, create a release, ship an update, cut a build, push a release to GitHub, or update the appcast. Also use when they mention archiving, notarization, DMG creation, Sparkle signing, bumping the version/build, the Homebrew cask, or anything related to building and distributing a new Bucket List version."
---

# Release Bucket List

Bucket List is released with a custom Go CLI, `cmd/bucketlist-release`. It can run **fully automated and non-interactively**, so an agent can run a release end to end from a chat session.

There are two modes:

- **Full auto (`-build`):** archive, export with Developer ID, notarize, staple, package, sign and publish. Nothing needs Xcode's GUI.
- **Package-only (no `-build`):** assumes the user already exported a notarized `~/Downloads/Bucket List.app` from Xcode, then packages and publishes it.

Use full auto unless the user says they've already exported the app.

## Prerequisites

Always required:

1. Tools: `create-dmg` (brew), `gh` (authenticated GitHub CLI), `git`, `plutil` and `go`.
2. The Sparkle `sign_update` binary in DerivedData. Building or archiving the project creates it, and the `-build` flow does this automatically.
3. The Sparkle EdDSA private key in the login keychain. It's shared with Screendrop and Lotion, and `generate_keys -p` must print the `SUPublicEDKey` listed below.

For full auto (`-build`), also:

4. `xcodebuild`, `xcrun` and `ditto` from Xcode 27. If the active developer directory is the Command Line Tools, the CLI points `DEVELOPER_DIR` at `/Applications/Xcode.app` itself.
5. A **notarytool keychain profile**. The default is `screendrop-notary`, an App Store Connect API key for team `TB2S44TFQS` that's shared with Screendrop. If it's missing, create it (or another profile and pass it with `-notary-profile`):
   ```bash
   xcrun notarytool store-credentials "screendrop-notary" \
     --key /path/to/AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer <issuer-uuid>
   ```

## The release CLI

Source: `/Users/fayazahmed/Developer/fayazara/mac/Bucket List/cmd/bucketlist-release/`

### Flags

- `-build`: run the archive → export → notarize → staple phase first.
- `-set-version <x.y.z>`: set `MARKETING_VERSION` before archiving and commit it. Use with `-build`.
- `-set-build <n>`: set `CURRENT_PROJECT_VERSION` before archiving and commit it. Use with `-build`.
- `-scheme <name>`: the Xcode scheme to archive. Default: `Bucket List`.
- `-notes "<text>"`: release notes, one bullet per line. Leading `- ` markers are stripped. Skips the interactive prompt.
- `-notes-file <path>`: read release notes from a file instead.
- `-notary-profile <name>`: the notarytool keychain profile. Default: `screendrop-notary`.
- `-yes` / `-y`: answer yes to every confirmation prompt (non-interactive).

### Running a full release (recommended)

1. **Decide the version and build number.** The build number (`CURRENT_PROJECT_VERSION`) **must increase** with every release, or Sparkle won't offer the update. The project uses Xcode's JSON-style `project.xcproj`, not `project.pbxproj`. Check the current values:
   ```bash
   grep -E "MARKETING_VERSION|CURRENT_PROJECT_VERSION" \
     "Bucket List.xcodeproj/project.xcproj" | sort -u
   ```
   Pick the next `MARKETING_VERSION` as real dotted semver, such as `0.2.1`, and never go backwards. Set `CURRENT_PROJECT_VERSION` to the current value plus 1.
2. **Write release notes** from the commits since the last tag (`git log $(git describe --tags --abbrev=0)..HEAD --oneline`). Use plain, user-facing language, one bullet per change users would care about. For the first release, `git describe` has no tag to find, so summarize the app instead.
3. **Commit and push code changes** to `main` first, so the release tag points at the released source. The CLI commits and pushes the version bump and the appcast, but it doesn't commit any other changes.
4. **Run it.** It's non-interactive and safe to run from a tool call:
   ```bash
   cd "/Users/fayazahmed/Developer/fayazara/mac/Bucket List" && \
   go run ./cmd/bucketlist-release -build -yes \
     -set-version <x.y.z> -set-build <n> \
     -notes "First note
   Second note"
   ```
   Archiving and notarization take several minutes, so a long wait is expected. Run it in the background or with a generous timeout (about 10 minutes).

### Package-only (the user already exported the app)

```bash
cd "/Users/fayazahmed/Developer/fayazara/mac/Bucket List" && \
go run ./cmd/bucketlist-release -yes -notes "Your notes here"
```

### What it does, in order

With `-build`:

1. **Set version/build** (if `-set-version` or `-set-build` is given): edits `project.xcproj` and commits.
2. **Archive:** `xcodebuild archive` (scheme `Bucket List`, Release, `generic/platform=macOS`).
3. **Export:** `xcodebuild -exportArchive` with a generated Developer ID `ExportOptions.plist`.
4. **Notarize:** zips the app, runs `xcrun notarytool submit --wait` and checks for `status: Accepted`.
5. **Staple:** `xcrun stapler staple`, then copies the app to `~/Downloads/Bucket List.app`.

Then, in both modes:

6. **Preflight and validate:** checks the app's version, build and Sparkle keys.
7. **Collect release notes** from `-notes` or `-notes-file`, otherwise from stdin.
8. **Create the DMG** with `create-dmg` at `~/Downloads/BucketList.dmg`. The DMG name has no space, so the download URL stays clean.
9. **Sign the DMG** with Sparkle's `sign_update` (EdDSA).
10. **Push commits:** pushes local commits, such as the version bump, to `main`.
11. **Create the GitHub release:** `gh release create vX.Y.Z` with the DMG attached.
12. **Update and push `appcast.xml`:** adds the new `<item>` at the top, replacing any existing entry for the same build, then commits and pushes to `main`.
13. **Update the Homebrew cask:** regenerates `Casks/bucket-list.rb` and pushes it to `fayazara/homebrew-tap`. A failure here doesn't stop the release.

**Ordering and robustness:** the GitHub release is created **before** the appcast is pushed, so the published appcast never points at a missing release. Network operations (`gh`, `git push`) are retried with backoff. Re-running a release is safe: if the GitHub release already exists, the DMG is re-uploaded (`--clobber`), and the appcast entry for that build is replaced, not duplicated.

### Environment and constants

- **Repo:** found from the working directory, otherwise `~/Developer/fayazara/mac/Bucket List`. Override with `BUCKETLIST_REPO`. This is its own git repo, separate from the parent `mac` folder.
- **GitHub:** repo `fayazara/BucketList`, branch `main`.
- **Signing:** team `TB2S44TFQS`, bundle ID `com.fayazahmed.Bucket-List`.
- **DMG:** volume name `Bucket List`. Minimum macOS: `26.0`.
- **Homebrew tap:** a temporary clone, or a local clone set with `BUCKETLIST_TAP_DIR`.

## Sparkle configuration

- **`Info.plist`** at the repo root, merged into the generated Info.plist through `INFOPLIST_FILE`:
  - `SUFeedURL`: `https://raw.githubusercontent.com/fayazara/BucketList/main/appcast.xml`
  - `SUPublicEDKey`: `MA/6n0fqT0T2updDlkXr8BjhJKoHWik9uf6Lh5pUG7U=`
  - `SUEnableInstallerLauncherService`: `YES`. Required because the app is sandboxed.
  - It also holds the `NSServices` entry for Finder's "Upload with Bucket List".
- **`Bucket List.entitlements`** at the repo root. It contains the sandbox, the network client and server entitlements (the server one is for the OAuth loopback listener), read-only access to user-selected files and read-write access to Downloads. It also has the `$(PRODUCT_BUNDLE_IDENTIFIER)-spks` and `-spki` mach-lookup exceptions that Sparkle's installer needs inside the sandbox. Keep these files outside the `Bucket List/` source folder: that folder is synchronized into the target, so anything in it is copied into the app as a resource.
- **`Bucket List/Support/UpdaterManager.swift`** is a singleton started from `AppDelegate.applicationDidFinishLaunching`. It only runs in Release builds; Debug builds never check for updates. The UI is **Bucket List → Check for Updates…** and **Settings → Updates**.

## After releasing

Check that the release worked:

```bash
gh release view v<x.y.z> --repo fayazara/BucketList --json tagName,assets -q '{tag: .tagName, assets: [.assets[].name]}'
curl -s https://raw.githubusercontent.com/fayazara/BucketList/main/appcast.xml | grep -E "shortVersionString|url="
```

## Troubleshooting

- **Partial failure or network error mid-release:** re-run the exact same command. The pipeline is safe to repeat.
- **notarytool credentials error:** the keychain profile is missing or invalid. Ask the user to re-run `store-credentials`.
- **Notarization "Invalid":** inspect it with `xcrun notarytool log <submission-id> --keychain-profile screendrop-notary`. The usual cause is signing or entitlements, such as an unsigned nested binary.
- **`xcodebuild archive` fails:** the CLI prints the last ~40 lines of output. Check that the scheme is `Bucket List` and that Sparkle resolves (it needs network access).
- **"Bucket List.app not found" (package-only mode):** export the app from Xcode first, or use `-build`.
- **"sign_update not found":** build or archive the project once so DerivedData has Sparkle's tools. The DerivedData folder is named `Bucket_List-…`.
- **The update downloads but won't install:** the sandbox pieces are missing. Check `SUEnableInstallerLauncherService` in the built Info.plist and the `-spks`/`-spki` entitlements with `codesign -d --entitlements - "Bucket List.app"`.
- **gh isn't authenticated:** run `gh auth login`.
- **The build number is already in the appcast:** a new release needs a higher build number, so bump `-set-build`.
