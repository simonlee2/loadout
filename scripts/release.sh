#!/usr/bin/env bash
#
# release.sh — build, sign, notarize, and package Loadout for distribution,
# and produce a Sparkle appcast.
#
# Usage:
#   scripts/release.sh [--version X.Y.Z] [--dry-run] [--skip-notarize] [--clean]
#
#   --version X.Y.Z   Set the release version. Updates App/project.yml
#                     (MARKETING_VERSION + CFBundleShortVersionString). When
#                     omitted, the current version is read from project.yml.
#   --dry-run         Build the whole pipeline WITHOUT a Developer ID cert:
#                     signs with the everyday Apple Development identity, skips
#                     -exportArchive/notarize, produces an unsigned DMG. Lets the
#                     pipeline be exercised today. Implies --skip-notarize.
#   --skip-notarize   Skip the notarytool submit + stapling steps.
#   --clean           Remove build/ before starting (forces a fresh archive).
#
# One-time setup for REAL (non-dry-run) releases is documented in
# docs/distribution.md — a "Developer ID Application" certificate and a
# notarytool keychain profile named "loadout-notary".

set -euo pipefail

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------
TEAM_ID="T3LQ95726F"
NOTARY_PROFILE="loadout-notary"
SCHEME="Loadout"
APP_NAME="Loadout"

# PLACEHOLDER: where the DMG + appcast will be hosted. Must match SUFeedURL in
# App/project.yml. Until hosting is decided this stays TBD; the appcast is still
# generated (with real EdDSA signatures) so only the URLs need substituting.
FEED_URL="https://github.com/simonlee2/loadout/releases/latest/download/appcast.xml"
DOWNLOAD_URL_PREFIX="https://github.com/simonlee2/loadout/releases/latest/download/"

# Repo layout (script lives in scripts/).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="$ROOT_DIR/App"
PROJECT_YML="$APP_DIR/project.yml"
XCODEPROJ="$APP_DIR/LoadoutApp.xcodeproj"
BUILD_DIR="$ROOT_DIR/build"
DERIVED_DATA="$BUILD_DIR/dd"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
RELEASES_DIR="$BUILD_DIR/releases"        # feeds Sparkle's generate_appcast
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"

# ----------------------------------------------------------------------------
# Argument parsing
# ----------------------------------------------------------------------------
VERSION=""
DRY_RUN=false
SKIP_NOTARIZE=false
CLEAN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --version=*) VERSION="${1#*=}"; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --skip-notarize) SKIP_NOTARIZE=true; shift ;;
    --clean) CLEAN=true; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

$DRY_RUN && SKIP_NOTARIZE=true

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m    WARN: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ----------------------------------------------------------------------------
# Step 0: preflight
# ----------------------------------------------------------------------------
step "Preflight"
command -v xcodegen >/dev/null || die "xcodegen not found (brew install xcodegen)"
command -v xcodebuild >/dev/null || die "xcodebuild not found (install Xcode)"
$CLEAN && { info "Cleaning $BUILD_DIR"; rm -rf "$BUILD_DIR"; }
mkdir -p "$BUILD_DIR"
$DRY_RUN && info "DRY RUN: Development signing, no Developer ID export, no notarization."

# ----------------------------------------------------------------------------
# Step 1: version
# ----------------------------------------------------------------------------
step "Version"
read_version() {
  grep -E '^[[:space:]]*CFBundleShortVersionString:' "$PROJECT_YML" \
    | head -1 | sed -E 's/.*"([^"]+)".*/\1/'
}
if [[ -n "$VERSION" ]]; then
  [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Version must be X.Y.Z (got '$VERSION')"
  info "Setting version to $VERSION in project.yml"
  # BSD sed in-place. Update both the build setting and the Info.plist value.
  sed -i '' -E "s/(MARKETING_VERSION:[[:space:]]*)\"[^\"]*\"/\1\"$VERSION\"/" "$PROJECT_YML"
  sed -i '' -E "s/(CFBundleShortVersionString:[[:space:]]*)\"[^\"]*\"/\1\"$VERSION\"/" "$PROJECT_YML"
else
  VERSION="$(read_version)"
  [[ -n "$VERSION" ]] || die "Could not read CFBundleShortVersionString from $PROJECT_YML"
  info "Using existing version $VERSION"
fi
DMG_PATH="$BUILD_DIR/$APP_NAME-$VERSION.dmg"

# ----------------------------------------------------------------------------
# Step 2: generate Xcode project
# ----------------------------------------------------------------------------
step "xcodegen generate"
( cd "$APP_DIR" && xcodegen generate --spec project.yml )

# ----------------------------------------------------------------------------
# Step 3: archive (Release, hardened runtime)
# ----------------------------------------------------------------------------
step "Archive (Release)"
if [[ -d "$ARCHIVE_PATH" && "$CLEAN" == false ]]; then
  info "Archive already exists at $ARCHIVE_PATH — skipping (use --clean to force)."
else
  # Always archive with automatic signing. The CloudKit entitlement requires a
  # provisioning profile, so pure ad-hoc signing is not an option; but the
  # everyday "Apple Development" identity + a managed development profile (minted
  # by -allowProvisioningUpdates) is enough to produce an archive whose app
  # carries the iCloud entitlements. For a real release, -exportArchive below
  # RE-SIGNS everything with the Developer ID identity, so a development-signed
  # archive is the correct input either way.
  info "Archiving Release with automatic signing (team $TEAM_ID)."
  set -o pipefail
  xcodebuild archive \
    -project "$XCODEPROJ" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    -derivedDataPath "$DERIVED_DATA" \
    -allowProvisioningUpdates \
    2>&1 | grep -E 'error:|ARCHIVE SUCCEEDED|ARCHIVE FAILED' || true
  [[ -d "$ARCHIVE_PATH" ]] || die "Archive failed — $ARCHIVE_PATH not produced."
fi

# ----------------------------------------------------------------------------
# Step 4: export the .app
# ----------------------------------------------------------------------------
step "Export app"
APP_PATH="$EXPORT_DIR/$APP_NAME.app"
if $DRY_RUN; then
  # -exportArchive with method developer-id needs a Developer ID cert we don't
  # have in a dry run, so lift the ad-hoc-signed .app straight out of the archive.
  info "Copying ad-hoc-signed app from archive (dry run — no -exportArchive)."
  rm -rf "$EXPORT_DIR"; mkdir -p "$EXPORT_DIR"
  cp -R "$ARCHIVE_PATH/Products/Applications/$APP_NAME.app" "$APP_PATH"
else
  cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
PLIST
  info "Exporting with Developer ID (ExportOptions.plist)."
  rm -rf "$EXPORT_DIR"
  set -o pipefail
  if ! xcodebuild -exportArchive \
      -archivePath "$ARCHIVE_PATH" \
      -exportOptionsPlist "$EXPORT_OPTIONS" \
      -exportPath "$EXPORT_DIR" \
      -allowProvisioningUpdates 2>&1 | tee "$BUILD_DIR/export.log"; then
    warn "-exportArchive failed. This usually means no 'Developer ID Application'"
    warn "certificate exists for team $TEAM_ID (even -allowProvisioningUpdates"
    warn "cannot always mint one headless)."
    warn "Create one: Xcode > Settings > Accounts > Manage Certificates > +"
    warn "  'Developer ID Application'. See docs/distribution.md."
    die  "Export failed (see $BUILD_DIR/export.log)."
  fi
  [[ -d "$APP_PATH" ]] || die "Export produced no app at $APP_PATH."
fi
info "App at $APP_PATH"

# Report signing + entitlements of the produced app.
info "Signature:"
codesign -dvv "$APP_PATH" 2>&1 | sed 's/^/      /' || true
info "Entitlements (expect CloudKit / iCloud):"
codesign -d --entitlements - --xml "$APP_PATH" 2>/dev/null \
  | plutil -p - 2>/dev/null | grep -iE 'icloud|cloudkit' | sed 's/^/      /' \
  || warn "Could not read entitlements."

# ----------------------------------------------------------------------------
# Step 5: notarize the app (real releases only)
# ----------------------------------------------------------------------------
if $SKIP_NOTARIZE; then
  step "Notarize app — SKIPPED"
else
  step "Notarize app"
  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    die "notarytool profile '$NOTARY_PROFILE' not found. Run once:
    xcrun notarytool store-credentials $NOTARY_PROFILE \\
      --apple-id <your-apple-id> --team-id $TEAM_ID --password <app-specific-password>
  (see docs/distribution.md), or pass --skip-notarize."
  fi
  # Notarize a zip of the app first so the .app itself is stapled before it goes
  # into the DMG (belt and braces — the DMG is also notarized below).
  APP_ZIP="$BUILD_DIR/$APP_NAME-$VERSION-app.zip"
  ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"
  info "Submitting app to notary service (waits for result)..."
  xcrun notarytool submit "$APP_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_PATH"
  info "App notarized and stapled."
fi

# ----------------------------------------------------------------------------
# Step 6: DMG
# ----------------------------------------------------------------------------
step "Build DMG"
STAGING="$BUILD_DIR/dmg-staging"
rm -rf "$STAGING"; mkdir -p "$STAGING"
cp -R "$APP_PATH" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH" >/dev/null
info "DMG at $DMG_PATH"

if ! $DRY_RUN; then
  # Sign the DMG with Developer ID so Gatekeeper trusts the container itself.
  DEVID_IDENTITY="$(security find-identity -v -p codesigning \
    | grep 'Developer ID Application' | head -1 | sed -E 's/.*"(.*)"/\1/')"
  if [[ -n "$DEVID_IDENTITY" ]]; then
    info "Signing DMG with: $DEVID_IDENTITY"
    codesign --force --sign "$DEVID_IDENTITY" --timestamp "$DMG_PATH"
  else
    warn "No 'Developer ID Application' identity found — DMG left unsigned."
  fi

  if ! $SKIP_NOTARIZE; then
    step "Notarize DMG"
    info "Submitting DMG to notary service (waits for result)..."
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG_PATH"
    info "DMG notarized and stapled."
  fi
fi

# ----------------------------------------------------------------------------
# Step 7: Sparkle appcast
# ----------------------------------------------------------------------------
step "Generate Sparkle appcast"
# Locate generate_appcast from the resolved SPM artifact (falls back to PATH).
GENERATE_APPCAST="$(find "$DERIVED_DATA/SourcePackages/artifacts" \
  -name generate_appcast -type f 2>/dev/null | head -1 || true)"
[[ -z "$GENERATE_APPCAST" ]] && GENERATE_APPCAST="$(command -v generate_appcast || true)"

if [[ -z "$GENERATE_APPCAST" ]]; then
  warn "generate_appcast not found — skipping appcast. (It ships with the"
  warn "resolved Sparkle SPM artifact under $DERIVED_DATA/SourcePackages/artifacts.)"
else
  info "Using $GENERATE_APPCAST"
  rm -rf "$RELEASES_DIR"; mkdir -p "$RELEASES_DIR"
  cp "$DMG_PATH" "$RELEASES_DIR/"
  # generate_appcast signs each update with the EdDSA private key stored in the
  # login keychain ("Private key for signing Sparkle updates"). It writes
  # appcast.xml into the releases dir. --download-url-prefix fills in the (still
  # placeholder) hosting URL so only that needs swapping once hosting is chosen.
  "$GENERATE_APPCAST" "$RELEASES_DIR" \
    --download-url-prefix "$DOWNLOAD_URL_PREFIX" || \
    warn "generate_appcast reported an issue (see output above)."
  if [[ -f "$RELEASES_DIR/appcast.xml" ]]; then
    cp "$RELEASES_DIR/appcast.xml" "$BUILD_DIR/appcast.xml"
    info "Appcast at $BUILD_DIR/appcast.xml (feed URL placeholder: $FEED_URL)"
  fi
fi

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
step "Done"
info "Version:  $VERSION"
info "App:      $APP_PATH"
info "DMG:      $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1 | tr -d ' '))"
[[ -f "$BUILD_DIR/appcast.xml" ]] && info "Appcast:  $BUILD_DIR/appcast.xml"
if $DRY_RUN; then
  info "This was a DRY RUN — the app is Development-signed (not Developer ID)"
  info "and the DMG is NOT notarized. Do not distribute it. Run without"
  info "--dry-run once the Developer ID cert and notarytool profile exist"
  info "(see docs/distribution.md)."
fi
