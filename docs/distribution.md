# Distributing Loadout

Loadout ships as a signed, notarized `.app` inside a DMG, and updates itself via
[Sparkle](https://sparkle-project.org). This is the runbook: what to set up once,
how to cut a release, and what still needs deciding.

Everything is driven by one script: **`scripts/release.sh`**.

---

## TL;DR — cut a release

```sh
# Test the whole pipeline today, no certificates required:
scripts/release.sh --dry-run --version 0.1.0

# A real, distributable release (after the one-time setup below):
scripts/release.sh --version 0.2.0
```

The output lands in `build/` (git-ignored): `Loadout-<version>.dmg` and
`appcast.xml`.

---

## One-time setup (real releases only)

A `--dry-run` needs none of this. A real release needs three things.

### 1. A "Developer ID Application" certificate

Notarized distribution requires a **Developer ID Application** signing identity
(distinct from the everyday "Apple Development" cert used for debug builds).

- **Easiest:** Xcode > Settings > Accounts > select the team (`T3LQ95726F`) >
  **Manage Certificates…** > **+** > **Developer ID Application**.
- **Headless attempt (tested):** the release script runs `xcodebuild
  -exportArchive -allowProvisioningUpdates`, which *can* mint missing certs
  automatically for some account types. On this machine it does **not** —
  running it against a real archive fails with:

  ```
  error: exportArchive No Accounts
  error: exportArchive No signing certificate "Developer ID Application" found
  error: exportArchive No profiles for 'com.simonlee.Loadout' were found
  ```

  So the Developer ID Application cert must be created via the Xcode UI above
  (only the account holder / Team Agent can, and there is a hard limit of 5 per
  team). The everyday "Apple Development" identity *is* present, which is why
  `--dry-run` archives fine.

Verify it exists:

```sh
security find-identity -v -p codesigning | grep "Developer ID Application"
```

### 2. A notarytool keychain profile

Apple's notary service needs credentials. Store them once in the Keychain under
the profile name the script expects (`loadout-notary`):

```sh
xcrun notarytool store-credentials loadout-notary \
  --apple-id <your-apple-id-email> \
  --team-id T3LQ95726F \
  --password <app-specific-password>
```

Create the **app-specific password** at <https://account.apple.com> > Sign-In &
Security > App-Specific Passwords. The script checks for this profile and fails
with instructions if it is missing.

### 3. The Sparkle signing key (already done)

Update packages are signed with an **EdDSA** key pair so Sparkle can verify them.

- The **public** key is baked into the app: `SUPublicEDKey` in
  `App/project.yml` →
  `oInuwhTVhUIkEXVwoEJNhYoFRUM0+cz8jhwUKgDlRy4=`.
- The **private** key lives in the **login Keychain** as
  **"Private key for signing Sparkle updates"**. `generate_appcast` reads it
  automatically when signing each release — nothing to configure.

> Back this up. If the private key is lost, existing installs can no longer
> verify updates and every user must reinstall manually. To inspect or export
> it, run Sparkle's `generate_keys -x <file>` (keep the export secret).

> **One-time keychain prompt:** the first time `generate_appcast` reads the
> private key, macOS shows a keychain access dialog ("generate_appcast wants to
> use a key…"). Click **Always Allow** — subsequent releases run without
> prompting. In a headless/CI context this dialog cannot be answered, so the
> first `generate_appcast` must be run on the desktop once. The release script
> treats an appcast failure as non-fatal (it warns and still emits the DMG), so
> a blocked prompt never aborts the build.

---

## Per-release flow

1. Pick the new version (semver `X.Y.Z`).
2. Run:

   ```sh
   scripts/release.sh --version X.Y.Z
   ```

   The script, in order:

   - writes the version into `App/project.yml`,
   - regenerates the Xcode project (`xcodegen`),
   - archives Release with **hardened runtime** on,
   - exports a **Developer ID**-signed `.app`,
   - **notarizes** the app, then the DMG, and **staples** both,
   - builds `build/Loadout-<version>.dmg`,
   - runs Sparkle's `generate_appcast` to produce `build/appcast.xml` with the
     EdDSA signature.

3. **Publish:** upload the DMG and `appcast.xml` to the release host (see
   *Open decisions* below).

### Flags

- `--dry-run` — full pipeline using the everyday **Apple Development** identity
  (no Developer ID cert needed), **no** `-exportArchive`/notarize, **unsigned**
  DMG. The archived app still carries hardened runtime + the CloudKit
  entitlements, so the pipeline is proven end-to-end. Implies `--skip-notarize`.
- `--skip-notarize` — build + sign + DMG but skip the notary steps.
- `--clean` — wipe `build/` first (forces a fresh archive).
- `--version X.Y.Z` — set and persist the version; omit to reuse the current one.

---

## How updates reach users

1. The app embeds Sparkle plus two Info.plist keys: `SUFeedURL` (the appcast
   URL) and `SUPublicEDKey` (the public key above).
2. On its schedule — and when the user picks **Loadout ▸ Check for Updates…** —
   Sparkle fetches `appcast.xml`, compares versions, and verifies the new
   build's EdDSA signature against the embedded public key.
3. If newer and valid, Sparkle downloads the DMG, verifies it, and installs the
   update in place.

The "Check for Updates…" menu item is wired in the app shell
(`App/LoadoutAppShell/UpdaterSetup.swift`) and injected into the app menu via a
small public hook on `LoadoutApp` — see the note in *Architecture* below.

---

## Open decisions (currently placeholders)

Two placeholders must be resolved before real updates work, then the values
updated in **both** `App/project.yml` and `scripts/release.sh`:

| What | Placeholder | Where |
| ---- | ----------- | ----- |
| Appcast feed URL | `https://RELEASES-HOST-TBD/appcast.xml` | `SUFeedURL` in `App/project.yml`; `FEED_URL` in `release.sh` |
| Download URL prefix | `https://RELEASES-HOST-TBD/` | `DOWNLOAD_URL_PREFIX` in `release.sh` |

**Hosting is undecided.** Any static HTTPS host works — GitHub Releases (+ a
raw `appcast.xml`), an S3/CloudFront bucket, or a project website. Pick one,
then substitute the two URLs above. The `appcast.xml` `generate_appcast`
produces already carries valid signatures; only the URLs change.

---

## Architecture note (why the app shell is separate)

`LoadoutKit` (the SwiftPM library with all the real code) is deliberately kept
**Sparkle-free** so `swift test` / `swift run Loadout` never need to resolve it.
Sparkle is a dependency of the **Xcode app shell only** (`App/project.yml`
`packages:` + the `Loadout` target). The shell's `main.swift` calls
`installSparkleUpdater()` (in `App/LoadoutAppShell/UpdaterSetup.swift`) before
`LoadoutApp.main()`; that function creates the `SPUStandardUpdaterController` and
sets `LoadoutApp.appInfoCommands` — a one-line public hook on `LoadoutApp` — to
inject the "Check for Updates…" menu item. This keeps the library portable and
the updater entirely in the signed bundle.
