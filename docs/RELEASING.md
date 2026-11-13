# Releasing Meter

Releases are built on this Mac. There is no CI. The flow mirrors Setu's.

## One-time setup (owner)

1. Create the GitHub repo (default `mukulchugh/meter`). To use another name, set `METER_REPO=owner/name` for every release command.
2. Make sure the Homebrew tap repo `mukulchugh/homebrew-tap` exists. Meter adds `Casks/meter.rb` to it.
3. `gh auth status` shows an account with push access to both repos.
4. The self-signed identity "Mukul Chugh Local Code Signing" is in the login keychain. Without it the app is signed ad-hoc, and the Keychain prompts again after every update. Override the name with `METER_SIGN_IDENTITY`.

## Steps

1. Bump `VERSION` (one line, for example `0.1.1`), commit, and push `main`.
2. Dry run:

   ```
   scripts/release.sh 0.1.1
   ```

   It checks that `VERSION` matches the argument, runs `scripts/test-swift.sh` (both suites, warnings are errors), builds a universal `dist/Meter.app` with `METER_UNIVERSAL=1 scripts/bundle-app.sh`, checks that it holds both arm64 and x86_64 and that its signature verifies, and packages `dist/Meter-0.1.1.zip` with `ditto -c -k --sequesterRsrc --keepParent` plus `dist/Meter-0.1.1.zip.sha256`. It also unpacks the zip to confirm the app inside still verifies, and renders `dist/meter.rb` so you can read the cask. On a test failure it prints the failing test names.

   A dry run with uncommitted changes prints a warning and builds them anyway. Never publish from that.

3. Publish:

   ```
   scripts/release.sh 0.1.1 --publish
   ```

   Before building, it requires a clean tree, `HEAD == origin/main`, that the app repo and the tap repo exist, and that tag `v0.1.1` is new. If the app repo does not exist it stops and says so. Then it:

   - creates the annotated tag `v0.1.1` and pushes it,
   - runs `gh release create v0.1.1` with the zip and the sha file,
   - clones the tap into a temp directory, writes `Casks/meter.rb` from `packaging/meter.rb.tmpl`, commits "meter 0.1.1" and pushes.

4. On a Mac: `brew update && brew upgrade --cask mukulchugh/tap/meter`.

## The cask

`packaging/meter.rb.tmpl` has three placeholders (`@VERSION@`, `@SHA256@`, `@REPO@`), filled by `scripts/render-cask.sh <version> <sha256> [repo]`.

- The `postflight` removes the quarantine attribute from the installed app. Meter is signed with a self-signed certificate and is not notarized, so without this Gatekeeper reports the app as "damaged". The sha256 check by Homebrew happens before that step.
- `zap` removes `~/Library/Application Support/Meter` and the preferences plist. It does not touch Keychain items, so a reinstall keeps the saved admin keys.
- `depends_on macos: ">= :tahoe"`: `:tahoe` is Homebrew's symbol for macOS 26 (checked against the installed Homebrew's `macos_version.rb`).

Check the template without publishing: `scripts/check-cask.sh` renders it with a fake version and sha, runs `ruby -c`, and runs `brew style` on it in a temp directory. The newest Homebrew reports two style notes (prefers `postflight_steps`, and a bare `depends_on macos: :tahoe`). They are advisory: older Homebrews do not understand either form, so the template keeps the long-standing ones.

## If something goes wrong

- Publish stopped before tagging: fix the cause and re-run. Nothing was changed.
- The tag was pushed but the release or the tap failed: the tag and any release exist. Finish by hand (`gh release create`, then commit `Casks/meter.rb` in the tap), or delete the tag and release and re-run. Do not reuse a version number with different bytes: Homebrew would fail the sha check for anyone who already installed it.
