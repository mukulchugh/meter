#!/usr/bin/env bash
# Build (and optionally publish) a Meter release on this Mac. No CI is involved.
#
#   scripts/release.sh 0.1.0            # dry run: test, build the universal app, package the zip, show the artifacts
#   scripts/release.sh 0.1.0 --publish  # also: tag v0.1.0, create the GitHub release, update the Homebrew tap
#
# Needs: the Swift toolchain (see scripts/swift-sdk.sh), `gh` signed in with push access to the app repo
# and to mukulchugh/homebrew-tap (publish only). METER_REPO overrides the app repo (default mukulchugh/meter).
# A dry run touches nothing outside the repo's dist/ folder and the temp directory, and uses no network.
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version> [--publish]}"
PUBLISH="${2:-}"
[ -z "$PUBLISH" ] || [ "$PUBLISH" = "--publish" ] || { echo "release: unknown option '$PUBLISH' (only --publish)" >&2; exit 1; }
TAG="v${VERSION}"
REPO="${METER_REPO:-mukulchugh/meter}"
TAP="mukulchugh/homebrew-tap"

die() { echo "release: $*" >&2; exit 1; }
say() { echo "release: $*"; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
DIST="$ROOT/dist"
ZIP="$DIST/Meter-$VERSION.zip"

[ "$(tr -d '[:space:]' < VERSION)" = "$VERSION" ] || die "VERSION says $(tr -d '[:space:]' < VERSION), not $VERSION; bump VERSION and commit first"

# A release is built from what is committed. The dry run only warns, so it can run mid-work;
# --publish refuses.
if [ -n "$(git status --porcelain)" ]; then
  if [ "$PUBLISH" = "--publish" ]; then die "working tree has changes; commit or move them first"; fi
  say "WARNING: working tree has changes; --publish would refuse. This build includes them."
fi

WORK="$(mktemp -d /tmp/meter-release.XXXXXX)"
trap 'rm -rf "${WORK:?}"' EXIT

if [ "$PUBLISH" = "--publish" ]; then
  have() { command -v "$1" >/dev/null 2>&1 || die "$1 is not installed"; }
  have gh
  git rev-parse -q --verify origin/main >/dev/null || die "no origin/main; add the remote and push main first"
  git fetch -q origin --tags
  [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || die "HEAD is not origin/main; push main first so the tag matches public source"
  gh repo view "$REPO" >/dev/null 2>&1 || die "the GitHub repo $REPO does not exist yet (or gh cannot see it). The owner has to create it first; set METER_REPO to use another name."
  gh repo view "$TAP" >/dev/null 2>&1 || die "the Homebrew tap repo $TAP does not exist (or gh cannot see it)"
  git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "tag $TAG already exists"
  gh release view "$TAG" -R "$REPO" >/dev/null 2>&1 && die "a GitHub release $TAG already exists"
fi

say "running the Swift tests"
if ! scripts/test-swift.sh > "$WORK/test.log" 2>&1; then
  echo "release: failing tests:" >&2
  grep -E "^✘|error:" "$WORK/test.log" | sort -u | head -40 >&2
  die "tests failed (full log: $WORK/test.log is removed on exit; re-run scripts/test-swift.sh to see it)"
fi
grep -E "Test run with" "$WORK/test.log"

say "building Meter.app (universal)"
METER_UNIVERSAL=1 scripts/bundle-app.sh > "$WORK/app.log" 2>&1 || { tail -20 "$WORK/app.log" >&2; die "Meter.app build failed"; }
grep -E "^signed|^built" "$WORK/app.log"
APP="$DIST/Meter.app"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/MeterApp" | tr ' ' '\n' | sort | tr '\n' ' ')"
[ "$ARCHS" = "arm64 x86_64 " ] || die "Meter.app is not universal (architectures: $ARCHS)"
codesign --verify --deep --strict "$APP" || die "Meter.app signature is not valid"
BUILT="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
[ "$BUILT" = "$VERSION" ] || die "Meter.app reports version $BUILT, expected $VERSION"

say "packaging $ZIP"
rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd "$DIST" && shasum -a 256 "Meter-$VERSION.zip" > "Meter-$VERSION.zip.sha256")
SHA="$(cut -d' ' -f1 "$ZIP.sha256")"

# The zip must unpack to a Meter.app that still verifies, which is what Homebrew will install.
mkdir -p "$WORK/unzip"
ditto -x -k "$ZIP" "$WORK/unzip"
codesign --verify --deep --strict "$WORK/unzip/Meter.app" || die "the app inside the zip does not verify"

scripts/render-cask.sh "$VERSION" "$SHA" "$REPO" > "$DIST/meter.rb"
ruby -c "$DIST/meter.rb" >/dev/null || die "the rendered cask is not valid Ruby"

say "artifacts:"
ls -l "$ZIP" "$ZIP.sha256" "$DIST/meter.rb"
say "sha256: $SHA"

if [ "$PUBLISH" != "--publish" ]; then
  say "dry run complete; nothing was tagged or published. Re-run with --publish to release."
  exit 0
fi

say "tagging $TAG at $(git rev-parse --short HEAD)"
git tag -a "$TAG" -m "meter $VERSION"
git push -q origin "$TAG"

say "creating the GitHub release"
gh release create "$TAG" -R "$REPO" --title "Meter $VERSION" --generate-notes "$ZIP" "$ZIP.sha256"

say "updating the Homebrew tap"
git clone -q "https://github.com/$TAP.git" "$WORK/tap"
mkdir -p "$WORK/tap/Casks"
scripts/render-cask.sh "$VERSION" "$SHA" "$REPO" > "$WORK/tap/Casks/meter.rb"
git -C "$WORK/tap" add Casks/meter.rb
git -C "$WORK/tap" commit -q -m "meter $VERSION"
git -C "$WORK/tap" push -q origin HEAD

say "done: brew update && brew upgrade --cask mukulchugh/tap/meter"
