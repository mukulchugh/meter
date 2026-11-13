#!/usr/bin/env bash
# Validate the cask template without publishing: render it with a fake version and sha, then run
# `ruby -c` and, when Homebrew is installed, `brew style --cask`. Changes nothing outside a temp dir.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /tmp/meter-cask.XXXXXX)"
trap 'rm -rf "${TMP:?}"' EXIT
FAKE_SHA="$(printf 'meter' | shasum -a 256 | cut -d' ' -f1)"
mkdir -p "$TMP/Casks"
"$ROOT/scripts/render-cask.sh" 9.9.9 "$FAKE_SHA" example/meter > "$TMP/Casks/meter.rb"
ruby -c "$TMP/Casks/meter.rb"
if command -v brew >/dev/null 2>&1; then
  # brew style only treats a file as a cask when it sits under a Casks/ directory. Style is advisory:
  # a newer Homebrew may prefer `postflight_steps` and a bare `depends_on macos: :tahoe`, which older
  # Homebrews do not understand, so offenses are printed but do not fail this script.
  brew style "$TMP/Casks/meter.rb" || echo "check-cask: brew style reported offenses (advisory, see above)"
else
  echo "check-cask: brew not installed, skipped brew style"
fi
