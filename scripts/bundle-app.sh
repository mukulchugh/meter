#!/bin/bash
# Build Meter.app: a release Swift build, the bundle assembled by hand, ad-hoc signed inside-out and
# verified. Output: <repo>/dist/Meter.app. Never launches the app.
#   METER_UNIVERSAL=1  one app for Apple silicon and Intel (separate scratch path per architecture, then lipo)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/Meter.app"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
: "${VERSION:?could not read the version from VERSION}"

# shellcheck source=swift-sdk.sh
. "$ROOT/scripts/swift-sdk.sh"
cd "$ROOT"
if [ "${METER_UNIVERSAL:-}" = 1 ]; then
  SLICES=()
  HELPER_SLICES=()
  for triple in arm64-apple-macosx26.0 x86_64-apple-macosx26.0; do
    scratch=".build-universal/${triple%%-*}"
    # One --product per build: SwiftPM honors only the last one given.
    for product in MeterApp meter-statusline; do
      swift build -c release --product "$product" ${SWIFT_SDK_ARGS[@]+"${SWIFT_SDK_ARGS[@]}"} --triple "$triple" --scratch-path "$scratch"
    done
    BIN_DIR="$(swift build -c release --product MeterApp ${SWIFT_SDK_ARGS[@]+"${SWIFT_SDK_ARGS[@]}"} --triple "$triple" --scratch-path "$scratch" --show-bin-path)"
    SLICES+=("$BIN_DIR/MeterApp")
    HELPER_SLICES+=("$BIN_DIR/meter-statusline")
  done
  TMP_BIN="$(mktemp -d)"
  SWIFT_BIN="$TMP_BIN/MeterApp"
  HELPER_BIN="$TMP_BIN/meter-statusline"
  lipo -create "${SLICES[@]}" -output "$SWIFT_BIN"
  lipo -create "${HELPER_SLICES[@]}" -output "$HELPER_BIN"
else
  for product in MeterApp meter-statusline; do
    swift build -c release --product "$product" ${SWIFT_SDK_ARGS[@]+"${SWIFT_SDK_ARGS[@]}"}
  done
  BIN_DIR="$(swift build -c release --product MeterApp ${SWIFT_SDK_ARGS[@]+"${SWIFT_SDK_ARGS[@]}"} --show-bin-path)"
  SWIFT_BIN="$BIN_DIR/MeterApp"
  HELPER_BIN="$BIN_DIR/meter-statusline"
fi

rm -rf "${APP:?}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
cp "$SWIFT_BIN" "$APP/Contents/MacOS/MeterApp"
# Claude Code's status line command (Settings, Plan usage, Enable points Claude Code at this file).
cp "$HELPER_BIN" "$APP/Contents/Resources/bin/meter-statusline"
chmod 755 "$APP/Contents/Resources/bin/meter-statusline"

# Icon: used only when the brand kit has one (brand/icon/Meter.iconset).
ICON_KEY=""
if [ -d "$ROOT/brand/icon/Meter.iconset" ]; then
  iconutil -c icns "$ROOT/brand/icon/Meter.iconset" -o "$APP/Contents/Resources/Meter.icns"
  ICON_KEY="  <key>CFBundleIconFile</key><string>Meter</string>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.meter.app</string>
  <key>CFBundleName</key><string>Meter</string>
  <key>CFBundleDisplayName</key><string>Meter</string>
  <key>CFBundleExecutable</key><string>MeterApp</string>
${ICON_KEY}
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Inside-out: the helper, then the executable, then the bundle.
# Sign with the stable self-signed identity when it's in the keychain, so every build has the
# same designated requirement (identifier + certificate) and the Keychain doesn't re-prompt
# after updates. Without it (another Mac, CI-less checkouts), fall back to ad-hoc.
SIGN_NAME="${METER_SIGN_IDENTITY:-Mukul Chugh Local Code Signing}"
# `|| true`: `security` exits 44 when the identity is missing, which pipefail would turn into a dead script
# instead of the ad-hoc fallback below.
SIGN_ID="$(security find-certificate -c "$SIGN_NAME" -Z 2>/dev/null | awk '/SHA-1 hash:/ {print $3; exit}' || true)"
if [ -n "$SIGN_ID" ]; then
  REQ="designated => identifier \"dev.meter.app\" and certificate leaf = H\"$SIGN_ID\""
  codesign --force --sign "$SIGN_ID" --timestamp=none --identifier dev.meter.statusline "$APP/Contents/Resources/bin/meter-statusline"
  codesign --force --sign "$SIGN_ID" --timestamp=none --identifier dev.meter.app -r="$REQ" "$APP/Contents/MacOS/MeterApp"
  codesign --force --sign "$SIGN_ID" --timestamp=none -r="$REQ" "$APP"
  echo "signed with \"$SIGN_NAME\" ($SIGN_ID)"
else
  codesign --force --sign - "$APP/Contents/Resources/bin/meter-statusline"
  codesign --force --sign - "$APP/Contents/MacOS/MeterApp"
  codesign --force --sign - "$APP"
  echo "signed ad-hoc (no \"$SIGN_NAME\" identity found); the Keychain may re-prompt after updates"
fi
codesign -v --strict "$APP"
echo "built $APP ($VERSION)"
