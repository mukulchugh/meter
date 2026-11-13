# Meter

Meter is a macOS menu bar app for a CTO who wants to see what the company spends on the Anthropic and OpenAI APIs. It shows today and month to date, whether the team is on track for its budget, who and what is driving spend (people, keys, projects, models), how fast prepaid credit and spend limits are being used, and Claude Code activity per person. Spend is split into App (production) and Team (developers) so you can tell the product from the people.

It reads cost and usage only, through each provider's official admin API. It cannot change anything in your accounts, and budgets are alerts: they never stop spend.

Requires macOS 26 (Tahoe) or later.

## Install

```
brew install --cask mukulchugh/tap/meter
```

Meter is signed with a personal certificate and is not notarized by Apple. The cask removes the download quarantine flag so macOS does not call the app damaged.

## Connect your organizations

Open Meter from the menu bar, choose Open Meter, then Connections, then Add organization. Paste an admin key. Meter checks it, loads history, and shows what each key can and cannot provide.

- **Anthropic:** in the Claude Console go to Settings, Admin keys, and create an admin key. It starts with `sk-ant-admin01-`. You need the admin role in a Console organization.
- **OpenAI:** at platform.openai.com go to Settings, Organization, Admin keys, and create one. It starts with `sk-admin-`. Organization owners can create admin keys.

The Admin API needs an organization account. Individual accounts cannot create admin keys, and Meter will say so if you try.

Admin keys are stored in the macOS Keychain, never in Meter's database or in any file. Use Rotate key in Connections to replace one, or Remove to delete it along with that organization's local history.

## Try it with sample data

With no organization connected, the popover and every empty screen offer Preview with sample data (the same switch is in Settings). It shows a made-up company with two Anthropic organizations and one OpenAI organization, a budget, a spend spike, a delayed report, and Claude Code activity for eight people. Sample data lives only in memory: it never touches your real data or Keychain, a banner reads "Sample data. Not your spend.", and Exit preview or adding a real organization ends it. Your choice is remembered across launches.

## Privacy

Everything stays on your Mac.

- Spend history is stored locally in `~/Library/Application Support/Meter`.
- Admin keys are in the Keychain.
- The only network calls are to the Anthropic and OpenAI admin APIs, using your keys, to read cost and usage.
- No telemetry, no analytics, no crash reporting, no accounts.

## Build from source

You need the Swift toolchain (Command Line Tools are enough) on macOS 26.

```
scripts/test-swift.sh        # both test suites; warnings are errors
scripts/bundle-app.sh        # builds dist/Meter.app (METER_UNIVERSAL=1 for Apple silicon and Intel)
```

`scripts/bundle-app.sh` signs with the self-signed identity "Mukul Chugh Local Code Signing" when it is in your keychain and falls back to ad-hoc signing otherwise. Releases are described in `docs/RELEASING.md`. Design notes are in `docs/PLAN.md` and `docs/CORE.md`.
