#!/usr/bin/env bash
# Render packaging/meter.rb.tmpl to stdout.   scripts/render-cask.sh <version> <sha256> [repo]
set -euo pipefail
VERSION="${1:?usage: render-cask.sh <version> <sha256> [repo]}"
SHA="${2:?usage: render-cask.sh <version> <sha256> [repo]}"
REPO="${3:-${METER_REPO:-mukulchugh/meter}}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ "$SHA" =~ ^[0-9a-f]{64}$ ]] || { echo "render-cask: sha256 must be 64 hex characters" >&2; exit 1; }
sed -e "s|@VERSION@|$VERSION|g" -e "s|@SHA256@|$SHA|g" -e "s|@REPO@|$REPO|g" "$ROOT/packaging/meter.rb.tmpl"
