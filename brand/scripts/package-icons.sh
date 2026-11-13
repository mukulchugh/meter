#!/bin/bash
set -euo pipefail

# Rebuild the standard macOS iconset from the approved 1024 px master.
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BRAND_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
SOURCE="$BRAND_DIR/icon/meter-icon-1024.png"
DEST="$BRAND_DIR/icon/Meter.iconset"

command -v sips >/dev/null 2>&1 || { echo "sips is required (macOS)." >&2; exit 1; }
command -v swift >/dev/null 2>&1 || { echo "swift is required (Xcode Command Line Tools)." >&2; exit 1; }
[[ -f "$SOURCE" ]] || { echo "Missing master: $SOURCE" >&2; exit 1; }

PROPERTIES="$(sips -g format -g pixelWidth -g pixelHeight "$SOURCE")"
FORMAT="$(awk '/^[[:space:]]*format:/ {print $2}' <<< "$PROPERTIES")"
WIDTH="$(awk '/^[[:space:]]*pixelWidth:/ {print $2}' <<< "$PROPERTIES")"
HEIGHT="$(awk '/^[[:space:]]*pixelHeight:/ {print $2}' <<< "$PROPERTIES")"
[[ "$FORMAT" == "png" && "$WIDTH" == "1024" && "$HEIGHT" == "1024" ]] || {
  echo "Master must be a 1024 x 1024 PNG; found $FORMAT $WIDTH x $HEIGHT." >&2
  exit 1
}

mkdir -p "$DEST"
for POINTS in 16 32 128 256 512; do
  for SCALE in 1 2; do
    PIXELS=$((POINTS * SCALE))
    SUFFIX=""
    [[ "$SCALE" == "1" ]] || SUFFIX="@2x"
    OUTPUT="$DEST/icon_${POINTS}x${POINTS}${SUFFIX}.png"
    sips -s format png -z "$PIXELS" "$PIXELS" "$SOURCE" --out "$OUTPUT" >/dev/null
    # Resampling may spread alpha outside the tile. Clear that spill at every size.
    swift "$SCRIPT_DIR/refine-light-icon.swift" "$OUTPUT"
  done
done
printf 'Packaged 10 PNGs in %s\n' "$DEST"
