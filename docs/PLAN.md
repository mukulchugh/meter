# Meter: plan for v1

## Who it's for
A CTO overseeing what the company spends on Anthropic and OpenAI. They want to answer:
1. **How much are we spending?** Today, this month, the trend, and whether we're on track for the budget.
2. **Is it the product or the team?** Production app keys and projects versus developers' keys, console use and Claude Code.
3. **Who and what is driving it?** By person, key, project or workspace, and model.
4. **Are we about to hit a limit or run out?** Spend limits, budgets, and how fast credits are being consumed.
5. **Is the team getting value from AI coding?** Claude Code sessions, lines changed, commits and PRs per person, against its cost.

## Data sources (official admin APIs only; details and URLs in RESEARCH.md)

| Question | Anthropic | OpenAI |
|---|---|---|
| Spend over time | `GET /v1/organizations/analytics/cost` (beta, 365 days, 4 to 24 h delay). Legacy `cost_report` (about 5 min fresh) for today. | `GET /v1/organization/costs` (daily buckets) |
| By person | `group_by` actor | `group_by` user |
| By key | `group_by` api key, plus key names from the API-keys list | `group_by` api key, plus project and key names |
| By project or workspace | `group_by` workspace, plus workspace names | `group_by` project, plus project names |
| By model | `group_by` model | from the `line_item` text |
| Tokens | usage report | `/v1/organization/usage/*` |
| Team AI coding | `usage_report/claude_code`: per person per day (sessions, lines, commits, PRs, estimated cost) | none for Codex at org level (check during build) |
| Limits | no API for workspace limits or credit balance | org and project hard limits and alerts are readable |

## Product vs team: one simple rule
Every key, project and workspace gets a tag the CTO sets once: **App**, **Team**, or **Untagged** (the default). Meter suggests a tag from names such as `prod`, `production`, `app` or `api` versus a person's name, `dev` or `local`, but never applies one without the CTO's say-so. All views split by tag, so "product vs team" is one glance.

## Screens

**Menu bar:** `$412 today`, one stable number, with month-to-date available in settings. When data is missing it shows an attention mark, never `$0`.

**Popover:**
1. Scope (both orgs) and reporting time.
2. Today's spend, split App / Team.
3. One row per provider: amount and "reported 3 h ago".
4. A 7-day chart.
5. The monthly budget bar, labelled "alert, does not stop spend".
6. Buttons: Open Meter, Refresh.

**Window (sidebar):**
- **Overview:** this month vs last month, the projected month-end against budget, App vs Team, and the top 5 drivers.
- **People:** spend per person, both providers merged when emails match. Claude Code activity next to their spend.
- **Keys & projects:** every key, project and workspace with its tag, spend, last use and owner. Spots unused or runaway keys.
- **Models:** spend and tokens by model; shows the mix and how cache use affects cost.
- **Budgets & alerts:**
  - monthly budgets overall, per tag and per project;
  - local notifications at 50, 80 and 100% and on spikes (a day over 2× the 14-day average);
  - OpenAI hard limits shown read-only.
- **Connections:** add or remove an organization (admin key, stored in the Keychain), its health, last report time, and what each key can see.

**Export:** CSV for finance, and a weekly summary as a local notification and a markdown file.

## Principles (from UX-RESEARCH.md)
- **Every number says what it is:** provider-reported cost, or an estimate. Never add the two together.
- **Show coverage:** "reported up to 06:00 UTC", not just "refreshed".
- **Failure stays visible:** missing data never looks like zero, and the last known value is kept with an attention state.
- **Simple flow:** total, then contributor, then detail. No dashboard crammed into the popover.
- **Sign-in:** admin keys only. No cookies, no borrowed logins, at most one Keychain prompt.

## Build
- **Stack:** SwiftUI on macOS 26 with Liquid Glass, Setu's brand system adapted, and a small Swift core with a local SQLite history. No server, no CI, free.
- **Polling:** Anthropic once per minute at most, only while something is visible; otherwise every 15 to 60 minutes. OpenAI hourly. History is kept locally beyond Anthropic's 365 days.
- **Keychain:** a stable self-signed certificate per build, so updates don't re-prompt. Prove it with a spike first.
- **Releases:** a local release script and the same Homebrew tap (`brew install mukulchugh/tap/meter`).

## Decisions (owner, 2026-11-13)
- **Several organizations per provider.** Views show them combined or one at a time, and every number names its organization.
- **OpenAI credits: both.**
  - Spend against the organization and project hard limits, read from the API, with a projected date for hitting each limit.
  - A prepaid balance the CTO enters after each top-up. Meter subtracts the reported spend since that entry and shows the remaining balance and the days left at the current rate. It is clearly labelled as an estimate from a manually entered balance.
- **Reports stay on the Mac for now:** a weekly notification, a markdown summary and CSV export. Slack or email can come later.
- **Name:** Meter, for now.

## Verification
Real keys from the owner, read-only calls only, checked against the two consoles' own numbers for the same days. Nothing ships until the totals match.
