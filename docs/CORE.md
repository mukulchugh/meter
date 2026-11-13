# MeterCore: a tour for the UI lane

`MeterCore` is the data layer. No UI, no third-party packages: Foundation, Security and the system SQLite only. Everything public is a `Sendable` value type, an actor or a protocol. Swift 6, macOS 26.

Build and test (Command Line Tools only): `scripts/test-swift.sh`. It builds against the macOS 26 SDK and treats warnings as errors.

## The shape

```
Secrets (Keychain)  ->  SyncEngine (actor)  ->  MeterStore (actor, SQLite)  ->  MeterSnapshot (value)  ->  queries
                            |                                                    ^
                     ProviderClient (Anthropic, OpenAI) over HTTPTransport       pure functions, take `now`
```

1. `SyncEngine` polls the providers and writes to `MeterStore`.
2. The UI calls `store.snapshot()` to get an immutable `MeterSnapshot`.
3. Every number on screen comes from a method on `MeterSnapshot`. They are pure: same snapshot and same `now`, same answer. Re-take the snapshot after a sync.

## Setup

```swift
let store = try MeterStore.openDefault()          // $METER_HOME/meter.db, else ~/Library/Application Support/Meter/meter.db
let secrets = KeychainSecrets()                   // real Keychain; tests use InMemorySecrets
let engine = SyncEngine(store: store, secrets: secrets)

let org = Org(id: UUID().uuidString, provider: .anthropic, displayName: "Acme")
try secrets.write(adminKey, for: org.keychainRef) // service "dev.meter.app", account = org id
try await store.upsertOrg(org)                    // the DB stores only the keychain reference string
let report = await engine.refresh(org: org)       // first sync backfills a year
await engine.setForeground(true)                  // popover or window visible: legacy "today" feed every 60 s
await engine.start()                              // background loop; engine.stop() ends it
```

`refresh(org:)` returns a `RefreshReport` with one `SyncOutcome` per source: `.updated(lines:)`, `.backedOff(until:)`, `.skipped`, or `.failed(ProviderError)`. `ProviderError.message` is plain-language text for the UI ("This key isn't an admin key...", "The Admin API isn't available for individual accounts...").

Several orgs per provider are normal. Every query takes a `CostFilter` (`orgIds`, `provider`, `tag`, `project`).

## Types

| Type | What it is |
|---|---|
| `Provider` | `.anthropic`, `.openai` |
| `Org` | id, provider, display name, `KeychainRef` |
| `CostLine` | `day: UTCDay`, `orgId`, `amount: Decimal` (USD), `source` (`.reported` or `.estimated`), `feed`, optional `model`, `apiKeyId`, `projectId`, `actor`, `serviceTier`, `lineItem` |
| `Entity` | a name from a list endpoint: `.apiKey`, `.project` (workspace or project), `.user` (with email) |
| `Tag`, `TagKind` | `.app`, `.team`, `.untagged`, set per key or project. A key's tag wins over its project's |
| `Budget`, `BudgetScope` | monthly USD; `.overall`, `.org`, `.tag`, `.project`; thresholds default 50/80/100 |
| `ClaudeCodeDay` | one person (or API key) per day: sessions, lines, commits, PRs, estimated cost |
| `Limit` | OpenAI hard limit or alert, `thresholdCents` |
| `PrepaidBalance` | amount, entered-at, org |
| `Coverage` | per org and `SyncSource`: `lastSuccess`, `watermark`, `coveredFrom`, `coveredThrough`, `lastError`, `unavailable`; `.state(now:)` gives a `FreshnessState` |
| `FreshnessState` | `connected, fresh, delayed, stale, error, unavailableDimension, noActivity` |
| `UTCDay` | a UTC calendar day: `.string`, `.adding(_:)`, `.monthStart`, `UTCDay(date)` |

`CostFeed` records where a line came from (`anthropicAnalytics`, `anthropicLegacy`, `openaiCosts`, `openaiCostsByUser`). The by-user feed is a second view of the same OpenAI dollars, so it is excluded from every total.

## The trust rules, as the API enforces them

- **Never zero for missing data.** Totals return a `Reading`: `amount: Decimal?` and a `ReadingState`.
  - `.value`: covered, with spend.
  - `.noActivity`: covered and confirmed zero. The only case where `$0` is true.
  - `.partial`: some orgs or days are not covered. Coverage is a set of unbroken day spans per org (`Coverage.coveredFrom` to `coveredThrough`, feeds merged where they abut), so a feed that stopped midway, a skipped history window or a rate-limited analytics feed shows up as a gap. `amount` is what is known, `missingOrgIds` says who.
  - `.missing`: nothing covers the period. `amount` is `nil`. Show an attention mark, not `$0`.
- **Never sum estimated with reported.** All totals, series, drivers and budgets use `source == .reported` only. `estimatedTotal(...)` and `claudeCodeActivity(...)` carry estimates separately. Label them "estimate".
- **Retain last known values.** A failed sync records the error in `Coverage` and leaves stored lines alone. Show `coverageSummary` next to the number.
- `Reading.basisLabel` is `"Provider-reported API cost"`. Put it beside the number.

## Queries

All are methods on `MeterSnapshot`; `now` is always passed in.

```swift
let snap = try await store.snapshot()
let now = Date()

// Totals
snap.today(now: now)                                  // Reading
snap.monthToDate(now: now, filter: .init(provider: .openai))
snap.previousMonth(now: now)
snap.total(from: d1, to: d2)
snap.totalsByOrg(from: m, to: today)                  // [OrgTotal]
snap.totalsByProvider(from: m, to: today)             // [ProviderTotal]
snap.totalsByTag(from: m, to: today)                  // [TagTotal], app, team, untagged

// Charts
snap.weekSeries(now: now)                             // [DailyPoint], 7 days, oldest first
snap.monthSeries(now: now)                            // 30 days; a day can be .missing, not 0

// Drivers
snap.topDrivers(.model, limit: 5, from: m, to: today) // .model .apiKey .project .person
snap.people(from: m, to: today)                       // PeopleResult: merged by lower-cased email, plus `unmatched`

// Projection, budgets, limits, prepaid
snap.projection(now: now)                             // run rate (last 7 covered days) AND elapsed-fraction projection, both shown
snap.budgetStatuses(now: now)                         // used, percent, thresholdsCrossed, projectedCrossing
snap.limitStatuses(now: now)                          // OpenAI limits: used, percent, projected date
snap.prepaidStatus(orgId: id, now: now)               // remaining (estimate), daysLeft, projectedRunOut
snap.spikes(now: now)                                 // day > 2x the 14-day average

// Claude Code and coverage
snap.claudeCodeActivity(from: m, to: today)           // per person: activity, estimatedCost, reportedSpend
snap.coverageSummary(now: now)                        // per org and source state, needsAttention, dataThrough
snap.tagSuggestions()                                 // proposals only; apply with store.setTag
```

Notes for the screens:

- **Menu bar:** `snap.today(now:)`. If `state == .missing` or `coverageSummary(now:).needsAttention`, show the attention mark. `needsAttention` is true only when a dollar feed is in error or stale; normal analytics lag (`delayed`) and a refused per-user pass do not set it.
- **People:** `people()` ties Anthropic `actor` and OpenAI user ids to emails through `Entity`. `unmatched` lists actors with no email (`.noUserRecord`, `.noEmail`, `.nonUserActor`). Days that only came from the Anthropic legacy feed carry no actor, so a person's total can be lower than the org total.
- **Budgets:** the text for each row is `BudgetStatus.consequence` ("Alert target: does not stop requests") or `LimitStatus.consequence` ("Provider-enforced limit").
- **Prepaid:** `PrepaidStatus.label` is the "estimate from a manually entered balance" text.
- **Projection:** `projectedByRunRate` is nil with fewer than 3 covered days in the last 7.

## Writing user settings

```swift
try await store.setTag(Tag(orgId: o, target: .apiKey, targetId: keyId, kind: .app))   // .untagged removes
try await store.upsertBudget(Budget(name: "Monthly", scope: .overall, amount: 5000))
try await store.setPrepaid(PrepaidBalance(orgId: o, amount: 2000, enteredAt: Date()))
try await store.setSetting("poll.background", "900")
```

## Export

```swift
let csv = Export.csv(snap, from: start, to: end)         // every dimension, names, tags, basis, counts_toward_total
let md  = Export.weeklySummary(snap, now: now)           // markdown; write to a file or a notification
```

CSV rows from the by-user OpenAI feed and any `estimated` rows have `counts_toward_total = false`. Finance should filter on that column.

## Sync behaviour

- First sync: Anthropic analytics in 31-day windows from 2026-01-01 (the API floor) or 365 days back; OpenAI 365 days in 180-day windows; Claude Code 30 days.
- Later syncs refetch the trailing 3 days. Replaced days are swapped wholesale, so a restated day that lost a row does not keep it.
- Anthropic analytics only stores days it has fully reported (day end at or before `data_refreshed_at`). The legacy `cost_report` feed starts the day after analytics coverage ends (at most 60 days back) and runs to today, and its lines are removed once analytics covers the day. Nothing is counted twice, even if analytics later fails. Today's Anthropic spend therefore comes from legacy, which has workspace and model but no API key, so it can be tagged by workspace only, not by key.
- Cadence: legacy at most every 60 s in foreground, 15 minutes in background (`SyncConfig.backgroundLegacyInterval`, 15 to 60 minutes); analytics, OpenAI, Claude Code and limits hourly; names daily.
- 429 and 5xx back off: `Retry-After` if sent, otherwise 60 s doubling to an hour. Auth errors stop the org's remaining sources for that pass and show as `.error`.

## Testing seams

`HTTPTransport` (inject a fake), `ProviderClientFactory` (inject clients), `Secrets` (`InMemorySecrets`), `MeterStore.inMemory()`, and `now` closures. See `Tests/MeterCoreTests/Support.swift` for `FakeTransport`, `TestClock` and `World` (builds a snapshot without a database).
