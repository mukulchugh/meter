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
  for triple in arm64-apple-macosx26.0 x86_64-apple-macosx26.0; do
    scratch=".build-universal/${triple%%-*}"
    swift build -c release --product MeterApp ${SWIFT_SDK_ARGS[@]+"${SWIFT_SDK_ARGS[@]}"} --triple "$triple" --scratch-path "$scratch"
    SLICES+=("$(swift build -c release --product MeterApp ${SWIFT_SDK_ARGS[@]+"${SWIFT_SDK_ARGS[@]}"} --triple "$triple" --scratch-path "$scratch" --show-bin-path)/MeterApp")
  done
  SWIFT_BIN="$(mktemp -d)/MeterApp"
  lipo -create "${SLICES[@]}" -output "$SWIFT_BIN"
else
  swift build -c release --product MeterApp ${SWIFT_SDK_ARGS[@]+"${SWIFT_SDK_ARGS[@]}"}
  SWIFT_BIN="$(swift build -c release --product MeterApp ${SWIFT_SDK_ARGS[@]+"${SWIFT_SDK_ARGS[@]}"} --show-bin-path)/MeterApp"
fi

rm -rf "${APP:?}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SWIFT_BIN" "$APP/Contents/MacOS/MeterApp"

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

# Inside-out: the executable first, then the bundle.
codesign --force --sign - "$APP/Contents/MacOS/MeterApp"
codesign --force --sign - "$APP"
codesign -v --strict "$APP"
echo "built $APP ($VERSION)"
