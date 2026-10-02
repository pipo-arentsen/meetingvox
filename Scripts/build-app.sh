#!/usr/bin/env bash
# Builds MeetingVox.app from the release binary. Build only: it never installs,
# copies to /Applications, touches launchd, or launches the app.
#
#   Scripts/build-app.sh
#
# Output: .build/app/MeetingVox.app (under .build/, so git-ignored). The bundle is
# assembled, signed and verified in a staging directory next to it and only then
# swapped in, so a failed run never leaves a partial bundle at the final path and
# never deletes the previous good one.
#
# Environment:
#   MEETINGVOX_SIGN_IDENTITY  codesign identity to look for (default "MeetingVox Dev").
#                             Detection is read-only (`security find-identity`); if the
#                             identity is not listed the app is signed ad-hoc, with a
#                             loud warning. See Packaging/README.md to create the cert.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="MeetingVox"
IDENTITY="${MEETINGVOX_SIGN_IDENTITY:-MeetingVox Dev}"
OUT_DIR="$ROOT/.build/app"
FINAL_APP="$OUT_DIR/$APP_NAME.app"
PLISTBUDDY=/usr/libexec/PlistBuddy

say() { printf '==> %s\n' "$*"; }

# Staging lives under .build/ (same volume as the final path) so the final swap is
# a plain rename, not a cross-volume copy.
mkdir -p "$OUT_DIR"
WORK="$(mktemp -d "$OUT_DIR/.staging.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/$APP_NAME.app"

# 1. Compile. `-c release` must stay warning-free (project gate).
say "swift build -c release"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
BINARY="$BIN_DIR/$APP_NAME"
[[ -x "$BINARY" ]] || { echo "error: $BINARY not found" >&2; exit 1; }

# 2. Assemble the bundle from scratch, in staging, so nothing stale survives.
say "assembling $APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Packaging/Info.plist" "$APP/Contents/Info.plist"

# The login-item agent SMAppService.agent(plistName:) registers. It must sit at
# Contents/Library/LaunchAgents/<Label>.plist and is sealed by the app signature.
AGENT_PLIST="com.pipostudio.meetingvox.agent.plist"
mkdir -p "$APP/Contents/Library/LaunchAgents"
cp "$ROOT/Packaging/LaunchAgents/$AGENT_PLIST" "$APP/Contents/Library/LaunchAgents/$AGENT_PLIST"

# CFBundleVersion = commit count: monotonic, no extra state to maintain.
if ! BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null)" || [[ -z "$BUILD_NUMBER" ]]; then
    BUILD_NUMBER=1
    echo "warning: 'git rev-list --count HEAD' failed; falling back to CFBundleVersion=1" >&2
fi
"$PLISTBUDDY" -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"

# 3. Icon: generated from the feather SVG, never committed.
say "generating AppIcon.icns"
swift "$ROOT/Packaging/Icon/make-icon.swift" "$WORK/AppIcon.iconset"
iconutil -c icns "$WORK/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

# 4. Dependency resource bundles (SwiftPM puts them next to the binary). Copied into
#    Contents/Resources so they ship with the app, but note that SwiftPM's generated
#    `Bundle.module` accessor does NOT look there: it checks
#    Bundle.main.bundleURL/FluidAudio_FluidAudio.bundle (the .app root) and then
#    the absolute .build path it was compiled with. Only FluidAudio's TTS/CLI
#    code uses that accessor; MeetingVox's ASR path never does, so this is
#    currently harmless (and would only bite if TTS were ever used).
shopt -s nullglob
NESTED=()
for bundle in "$BIN_DIR"/*.bundle; do
    cp -R "$bundle" "$APP/Contents/Resources/"
    NESTED+=("$APP/Contents/Resources/$(basename "$bundle")")
done
shopt -u nullglob

# 5. Lint before signing, and check every required key is present.
say "plutil -lint"
plutil -lint "$APP/Contents/Info.plist"
for key in CFBundleIdentifier CFBundleExecutable CFBundlePackageType CFBundleName \
           CFBundleDisplayName CFBundleShortVersionString CFBundleVersion \
           LSMinimumSystemVersion LSUIElement CFBundleIconFile NSHighResolutionCapable \
           LSApplicationCategoryType NSMicrophoneUsageDescription \
           NSAudioCaptureUsageDescription NSLocalNetworkUsageDescription \
           NSAppTransportSecurity:NSAllowsLocalNetworking; do
    "$PLISTBUDDY" -c "Print :$key" "$APP/Contents/Info.plist" >/dev/null 2>&1 \
        || { echo "error: Info.plist is missing $key" >&2; exit 1; }
done
BUNDLE_ID="$("$PLISTBUDDY" -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")"

# The embedded agent: valid, named after its Label, running the bundle executable.
AGENT="$APP/Contents/Library/LaunchAgents/$AGENT_PLIST"
plutil -lint "$AGENT"
[[ "$("$PLISTBUDDY" -c "Print :Label" "$AGENT")" == "${AGENT_PLIST%.plist}" ]] \
    || { echo "error: $AGENT_PLIST: Label does not match the file name" >&2; exit 1; }
[[ "$("$PLISTBUDDY" -c "Print :BundleProgram" "$AGENT")" == "Contents/MacOS/$APP_NAME" ]] \
    || { echo "error: $AGENT_PLIST: BundleProgram is not Contents/MacOS/$APP_NAME" >&2; exit 1; }
if "$PLISTBUDDY" -c "Print :StandardErrorPath" "$AGENT" >/dev/null 2>&1; then
    echo "error: $AGENT_PLIST must not set StandardErrorPath (launchd does not expand ~)" >&2; exit 1
fi

# 6. Sign. Not sandboxed, no hardened runtime (no `--options runtime`): without
#    notarization it buys nothing, and library validation would risk the
#    FluidAudio/CoreML dlopen.
# Capture the listing first: piping straight into `grep -q` can SIGPIPE
# `security` and trip pipefail. The lookup is read-only.
IDENTITIES="$(security find-identity -v -p codesigning || true)"
MATCHES="$(grep -cF -- "\"$IDENTITY\"" <<<"$IDENTITIES" || true)"
if (( MATCHES > 1 )); then
    echo "error: $MATCHES valid code-signing identities are named \"$IDENTITY\"; refusing to guess." >&2
    echo "       Remove the duplicates in Keychain Access, or set MEETINGVOX_SIGN_IDENTITY to a unique name/hash." >&2
    exit 1
elif (( MATCHES == 1 )); then
    SIGN_ID="$IDENTITY"
    say "signing with identity \"$IDENTITY\""
else
    SIGN_ID="-"
    cat >&2 <<WARN

##############################################################################
# WARNING: signing identity "$IDENTITY" not found - signing AD-HOC.
#
# An ad-hoc signature changes with every build, so macOS will forget the
# Microphone / System Audio / Local Network grants and the Keychain will ask
# again after each rebuild. Create the certificate once (Packaging/README.md)
# and rebuild to get a stable signature.
##############################################################################

WARN
    say "signing ad-hoc"
fi

sign() {
    codesign --force --sign "$SIGN_ID" --timestamp=none "$@"
}
# Nested bundles first: an outer signature seals the inner ones. SwiftPM resource
# bundles without an Info.plist (FluidAudio's is a flat folder of data files)
# are not signable code; the app's own signature seals them as plain resources.
for nested in ${NESTED[@]+"${NESTED[@]}"}; do
    if [[ -f "$nested/Info.plist" || -f "$nested/Contents/Info.plist" ]]; then
        sign "$nested"
    else
        say "skipping $(basename "$nested") (data-only bundle, sealed by the app signature)"
    fi
done
sign --identifier "$BUNDLE_ID" --entitlements "$ROOT/Packaging/MeetingVox.entitlements" "$APP"

# 7. Verify and report.
say "codesign --verify --deep --strict"
codesign --verify --deep --strict --verbose=2 "$APP"
say "designated requirement"
codesign -d -r- "$APP" 2>&1 | grep -E '^(designated|# designated)' || true
say "signature details"
codesign -dv "$APP" 2>&1 | grep -E '^(Identifier|Signature|CodeDirectory|Authority|TeamIdentifier)' || true

# 8. Publish: only a verified bundle replaces the previous one.
say "publishing to $FINAL_APP"
rm -rf "$FINAL_APP"
mv "$APP" "$FINAL_APP"
codesign --verify --deep --strict "$FINAL_APP"

say "done: $FINAL_APP (version $("$PLISTBUDDY" -c 'Print :CFBundleShortVersionString' "$FINAL_APP/Contents/Info.plist"), build $BUILD_NUMBER)"
