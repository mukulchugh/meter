# Meter: UX/UI research and design recommendation

**My recommendation:** Meter should feel like a trustworthy financial instrument, not a miniature observability dashboard.

Its core promise should be:

> **What have I spent, what is consuming it, and do I need to act?**

Subscription monitoring can fit, but it must remain clearly separate from API spending.

**Research date: 13 November 2026.** I inspected the signed-in OpenAI and Anthropic interfaces, public dashboard screenshots and documentation, menu bar app screenshots, and specific community discussions. I made no billing or configuration changes. Personal account figures are omitted.

Below, **observed** means inspected UI or screenshots; **documented** means official behavior; **reported** means user feedback, not independently reproduced. Where an authenticated empty/error state was inaccessible, I say so rather than inventing one.

---

## 1. The distinctions Meter must get right

### API spend, subscription allowance, and local estimates are different products

Meter should have three explicitly named data categories:

1. **Provider-reported API cost**
2. **Subscription allowance**, expressed as usage or remaining quota and reset time
3. **Local API-equivalent estimate**, calculated from recorded tokens and prices

Never add these together into a single “total spend.”

<citation refs="VcLrU-t6gxWRsJ0LbIwzi">Claude subscriptions and Claude Console API billing are separate products, although some plans now include API credits.</citation> <citation refs="PlzreY6h6LRoxDBh7Jvz9">OpenAI explicitly warns that API token prices should not be used to estimate included subscription tasks.</citation>

### “Refreshed just now” does not mean the underlying usage is current

<citation refs="YcWdtamHqD68-yXvqTLh9">Anthropic’s newer Usage and Cost Analytics API typically refreshes within four hours, can take up to 24 hours, and can revise figures until about seven days after month-end. Its legacy reporting API typically exposes data within five minutes.</citation>

Meter needs **two timestamps when available**:

- **Fetched:** when Meter checked
- **Data through:** the provider’s reporting watermark

### A budget is not necessarily a spending stop

<citation refs="tvVZS-iS0GsITUhpI6XTP">Current OpenAI documentation distinguishes notification-only spend alerts from opt-in hard limits. Hard limits return errors, but enforcement can lag and spending can slightly overshoot.</citation>

The UI should say one of:

- **Alert target: does not stop requests**
- **Provider-enforced limit**
- **Gateway-enforced limit**
- **Estimated threshold**

Not simply “Budget.”

### Subscription schemas will keep changing

<citation refs="oRdQp5bQftdHKDVEXK1-1">Claude exposes session and weekly limits, with additional plan/model-specific limits.</citation> <citation refs="yMJzZex8ebMU3b9pm_-pv">OpenAI has announced shared ChatGPT/Codex allowances starting in December.</citation>

**Design implication:** do not hard-code “ChatGPT usage = one percentage” or assume every account always has a five-hour window.

---

# 2. Dashboard research

## OpenAI Platform usage and costs

**Inspected:** [live Usage dashboard](https://platform.openai.com/usage) and [Responses/Chat Completions detail](https://platform.openai.com/usage/chat-completions).

### What it shows

- **At a glance:** total spend, monthly spend context, total tokens, total requests, and capability-specific summaries.
- **Scope:** organization, independent dashboard project selector, API keys, API source, date range.
- **Breakdowns:** the spend grouping menu exposed API source, line item, project, API key, and user. Usage detail additionally exposed model, batch, and service tier.
- **Charts:** a prominent spend time series, smaller capability plots, and detailed usage intervals of one minute, one hour, or one day.
- **Navigation:** overview → capability → model/user/project/key detail. Export and refresh remain near the filters.

<citation refs="Mq1rosJ4wgD1OeMeVwcl4">The dashboard uses UTC, its project selector is independent of the platform-wide project selector, and selecting no projects means all projects. Usage intervals are not equivalent to billing granularity.</citation>

### Budgets, authentication, empty states

- **Observed empty state:** “No usage data” with an explanation that the selected date range and grouping have no data. This is better than presenting an unexplained blank chart.
- **Observed sign-in:** account selection before entering the API Platform.
- <citation refs="Mq1rosJ4wgD1OeMeVwcl4">Dashboard access requires organization ownership or Usage Dashboard permission.</citation>
- <citation refs="HPN_VYguI35aO1bMThm0t">Programmatic administrative access uses an Admin API key, not an ordinary inference key.</citation>
- <citation refs="tvVZS-iS0GsITUhpI6XTP">Spend alerts and hard limits are configured separately; hard-limit errors identify organization versus project scope.</citation>

I did not deliberately trigger authentication or billing errors.

### User feedback

<citation refs="synBkbJ-0CLWM4zLLprvh">A November 2025 support discussion shows users struggling with monthly-budget numbers, selected date ranges, project scope, and missing usage. Suggested filter fixes did not resolve the original reporter’s problem, so this should not be dismissed as merely user error.</citation>

<citation refs="QUAZG7mmZFvN1vC9K5msh">Another discussion describes difficulty discovering API-key breakdowns and recognizing named keys.</citation>

**Copy:** consistent filters, capability drilldown, explicit empty-state explanation.

**Improve:** keep the displayed total, chart, budget, and breakdown under unmistakably matching scopes and periods.

---

## Anthropic Console cost and usage

**Inspected:** [Cost](https://platform.claude.com/cost), [Usage](https://platform.claude.com/usage), and [Spend limits](https://platform.claude.com/settings/spend-limits).

### What it shows

The current live interface is more capable than some older help-page descriptions.

**Observed Cost page:**

- Total cost, token cost, web-search cost, code-execution cost, and session-runtime cost.
- A **“Data as of” timestamp directly beneath the title**.
- Workspace, API key, model, and agent filters.
- Grouping by model, token type, context window, batch, API key, agent, environment, service account, and inference geography.
- A **daily stacked-bar chart**, with a chart/table switch.
- Discounted token cost distinguished from list price.

**Observed Usage page:**

- Input tokens, output tokens, web searches.
- Workspace, key, account, model, and agent selectors.
- The same chart/table pattern and reporting timestamp.

<citation refs="e5IBIMnL7r2ODJFVuA7Kd">Official help also documents model/key/date filtering, CSV export, input/output token charts, rate-limited requests, and rate-limit-use visualizations.</citation>

### Budgets, access, missing data

- **Observed limits:** organization monthly usage meter, percentage used, reset date in UTC, and workspace limits.
- An unset workspace limit explicitly says the organization limit still applies.
- <citation refs="Zc-A8xrfzi2oVV1SJQDGh">Workspace settings distinguish a monthly cap from email notifications. Workspace limits must be below the organization limit, and the default workspace cannot receive its own spend limit.</citation>
- <citation refs="JdolwN__hHZmeepoFAZJM">Reporting credentials depend on the product: Console organizations use Admin credentials; Enterprise analytics uses an Analytics API key.</citation>
- **Observed loading state:** loading indicators occupied totals and chart areas before data arrived.
- Auth-error and genuine first-use empty states were not tested.

### User feedback

<citation refs="a_iA7om-xJ-NnqJWv8w_z">A detailed GitHub report describes confusion caused by API credits and subscription usage credits receiving similar “balance” treatment despite different mechanics.</citation>

<citation refs="2IzEygXx6d5Vi4u22oPHt">A related report says subscription users land in the developer Console expecting subscription billing controls, without a sufficiently clear product boundary.</citation>

These are reported experiences, not proof that every current screen still has the problem.

**Copy:** visible reporting watermark, separate tool costs, chart/table switch, inherited-limit explanation.

**Avoid:** ambiguous “balance” and “usage” labels shared across unrelated billing systems.

---

## OpenRouter Activity

**Inspected:** [official Activity documentation and screenshots](https://openrouter.ai/docs/guides/features/activity).

### What it shows

<citation refs="-3i8HZZxxKRWTm3b3d-BI">The redesigned Activity experience has Overview, Trends, Explore, and Guardrails. It supports model, provider, key, app, user, and organization-member filtering, with shared filter context across views.</citation>

**Observed overview screenshot:**

- Five cards: **spend, requests, token volume, cache-hit rate, blended cost per million tokens**.
- Sparklines and comparison states, including **“No prior data.”**
- Ranked **Top API Keys** and **Top Apps**.
- Model-usage bars.
- A restrained, predominantly white interface with purple selection emphasis.

<citation refs="-3i8HZZxxKRWTm3b3d-BI">Explore supports one or two grouping dimensions, time rollups, bar/line/dot plots, cumulative views, ranking, limits, and an Other group. Drilldowns preserve filters.</citation>

### Budgets, authentication, empty/error states

<citation refs="LeLDp6KcS-56SsKyvAfPa">Workspace, member, and key controls can stack; exhausting an applicable limit blocks requests. Attribution follows key ownership, and BYOK inclusion must be understood separately.</citation>

<citation refs="g5wbb-XPtmTny3o9whW8D">Analytics access requires a Management API key. This is an account-wide administrative credential, not a narrowly scoped read-only analytics key.</citation>

<citation refs="vcvn3dDD8vBKjPlZV9PHx">Export documentation distinguishes credit spending from BYOK estimates at market prices, which may not reflect negotiated provider discounts.</citation>

Only the screenshot’s **“No prior data” comparison state** was verified. Live first-use, invalid-key, and backend-error screens were not.

### User feedback

A [runaway-agent report](https://github.com/openclaw/openclaw/issues/121199) illustrates the need to identify the responsible app, key, and model quickly. It is **not evidence of OpenRouter overbilling**, and the issue did not establish the precise shutdown sequence.

**Copy:** total → biggest contributors → preserved-context drilldown.

**Avoid:** exposing the entire flexible chart builder inside Meter’s popover.

---

## Vercel AI Gateway

**Inspected:** [observability](https://vercel.com/docs/ai-gateway/observability-and-spend/observability), [custom reporting](https://vercel.com/docs/ai-gateway/observability-and-spend/custom-reporting), and [budgets](https://vercel.com/docs/ai-gateway/observability-and-spend/budgets).

### What it shows

**Observed screenshot:** four compact chart panels:

- Spend by model
- Time to first token
- Requests by model
- Tokens

Each combines a headline number with a time series. The screenshot labels average TTFT; current documentation describes P50, so the image should not be treated as the authoritative statistical definition.

<citation refs="TRxMnOOotF977XCBRDNUI">Current observability supports team/project context, model-level requests and spend, latency metrics, API-key/project summaries, and request-log drilldowns.</citation>

<citation refs="kttI-N9g_ZcA3LLJduh52">Custom reporting adds user, model, provider, tag, credential type, and API-key dimensions. Data typically appears after a few minutes. Charged cost and market-equivalent cost are separate: BYOK has zero gateway-charged cost but can have market cost.</citation>

### Budgets and integration risks

<citation refs="2ICZeXmmi6u96hCZ4H6mM">Budgets support team, project, key, and user scopes, with daily, weekly, monthly, or cumulative periods. The crossing request can complete; subsequent requests receive a 402. Optional email thresholds are 50%, 75%, and 100%, and are off by default.</citation>

<citation refs="kttI-N9g_ZcA3LLJduh52">Custom reporting is restricted to eligible Pro/Enterprise accounts and costs $5 per thousand queries.</citation> Polling it once per minute continuously would therefore cost roughly **$216 per 30 days**. Meter must not make monitoring unexpectedly expensive.

<citation refs="KkNz0uSLLyjmGtT-mzySq">Gateway keys have names, optional expiry and project scope, and are shown only once.</citation>

Authenticated dashboard empty/error states were not inspected.

### User feedback

A [pricing-discrepancy discussion](https://community.vercel.com/t/ai-gateway-pricing-discrepancy-between-documented-rates-and-actual-charges/31756) includes a Vercel explanation that reasoning tokens had not been visible in the relevant presentation.

**Copy:** headline metric plus trend; scoped budget explanations.

**Avoid:** hiding chargeable token categories, mixing BYOK market value with actual gateway charges, or costly background polling.

---

## Cloudflare AI Gateway

**Inspected:** [analytics](https://developers.cloudflare.com/ai-gateway/observability/analytics/), [costs](https://developers.cloudflare.com/ai-gateway/observability/costs/), [spend limits](https://developers.cloudflare.com/ai-gateway/features/spend-limits/), and public identity/cost screenshots.

### What it shows

<citation refs="YnbyEWUmezx3wmGf2qtTq">Core analytics covers requests, tokens, cost, errors, and caching, with gateway and time filtering.</citation>

**Observed public identity/cost example:**

- Usage, Cost Attribution, Cost Controls, and Anomalies tabs.
- Active users and agents alongside requests and tokens.
- A stacked-area request chart.
- A ranked identity list that distinguishes users from agents.

That screenshot accompanied a beta-era announcement; it is not proof that every account currently has identical navigation.

<citation refs="JjvX4hoLPP-hkrxrGt79j">Newer User Insights documentation includes active users, adoption, median consumption/spend, concentrated activity, and users needing review.</citation>

### Costs, limits, authentication, states

<citation refs="xgMfRTWpHrdBgzBHrGE-2">Cloudflare describes costs as estimates, not authoritative invoices. Calculation depends on supported models, token information, and pricing; custom costs can represent negotiated rates.</citation>

<citation refs="_KouYGq0avc6OSZOh2KM_">Spend rules can use fixed or rolling windows and model/provider/metadata scopes. They can block requests with 429 or use configured routing alternatives. Tracking is eventually consistent, so concurrent traffic can overshoot.</citation>

<citation refs="YnbyEWUmezx3wmGf2qtTq">External analytics uses Cloudflare account/token access rather than an OpenAI or Anthropic inference key.</citation>

Live onboarding, empty-data, and authentication-error states were not verified. Notification availability should not be inferred from the existence of enforced limits.

### User feedback

A [specific HN complaint](https://news.ycombinator.com/item?id=47806253) alleged incorrect image-model pricing; a [Cloudflare response](https://news.ycombinator.com/item?id=47807392) promised investigation. Resolution was not established.

**Copy:** identity-based attribution and explicit cost controls.

**Avoid:** letting an estimated-price chart look like a reconciled bill.

---

## Helicone

**Inspected:** [cost tracking](https://docs.helicone.ai/guides/cookbooks/cost-tracking), [alerts](https://docs.helicone.ai/features/alerts), and [rate limits](https://docs.helicone.ai/features/advanced-usage/custom-rate-limits).

### What it shows

**Observed official screenshots:**

- Cost, requests, and average latency above a custom-property table.
- Readable feature names such as extraction, classification, and summarization.
- Request counts, total cost, average cost, and token/latency metrics per feature.
- Session distributions for requests, cost, and duration, with prominent averages.
- An alerts table with Healthy/Triggered status and a separate alert history.

This is a useful move from **“how much?” to “what does a typical workflow cost?”**

[Cost-tracking source and screenshots](https://docs.helicone.ai/guides/cookbooks/cost-tracking)

### Breakdown, controls, setup

- Attribution can use model/provider, user, session, and custom properties such as feature or environment.
- Coverage depends on instrumented or gateway traffic. It does not automatically represent every request in a provider account.
- Cost alerts support windows, thresholds, grouping, minimum traffic, and notification channels.
- **Enforcement is separate:** rate-limit policies can use cents, users, or custom properties and return 429 when exceeded.

[Integration](https://docs.helicone.ai/getting-started/quick-start) · [Alerts](https://docs.helicone.ai/features/alerts) · [Enforcement](https://docs.helicone.ai/features/advanced-usage/custom-rate-limits)

### States and feedback

- Unsupported pricing can display **“Cost Unsupported.”**
- The inspected sign-in page offered existing-user access, but also stated that new signups were disabled at observation time. Do not assume a new-account walkthrough is currently available.
- Live dashboard first-use and failure states were inaccessible.

[Observed sign-in destination](https://us.helicone.ai/signin?unauthorized=true)

A [launch discussion](https://news.ycombinator.com/item?id=35279155) praised per-request visibility and debugging value. Conversely, [unsupported-cost](https://github.com/Helicone/helicone/issues/5374) and [tier-pricing](https://github.com/Helicone/helicone/issues/5690) reports show why pricing coverage must remain visible. The unsupported-cost example was reported fixed.

**Copy:** named-feature attribution, average unit cost, alert history.

**Avoid:** excessive decimal precision and unqualified accuracy claims.

---

## Langfuse

**Inspected:** [cost dashboard screenshots and semantics](https://langfuse.com/docs/observability/features/token-and-cost-tracking), [custom dashboards](https://langfuse.com/docs/metrics/features/custom-dashboards), and [alerts](https://langfuse.com/docs/observability/features/alerts).

### What it shows

**Observed official cost dashboard:**

- Trace and observation counts.
- Total-cost time series.
- Cost by model bars.
- Environment doughnut.
- Top users by cost.
- Top use cases at both trace and observation level.

The distinction is valuable:

- **Trace:** the workflow
- **Observation:** an individual step

The weakness at small sizes is truncated identifiers, tiny long-tail bars, and a large doughnut that uses space inefficiently.

### Breakdown, alerts, setup

- Dashboards are project-scoped, with model, user, time, trace name, tags, metadata, and environment filtering.
- Custom line, bar, time-series, and pie widgets support exploration.
- Alerts distinguish warning/alert thresholds, recovery, re-notification, and **NO_DATA** handling.
- A provider-spend hard cap was not established.

[Dashboard capabilities](https://langfuse.com/docs/metrics/features/custom-dashboards) · [Alert semantics](https://langfuse.com/docs/observability/features/alerts)

Setup uses a Langfuse project’s public/secret credentials and instrumentation. It is not interchangeable with a provider billing credential.

[Setup](https://langfuse.com/docs/observability/get-started)

### Cost and error semantics

Current documentation says:

- Token usage must be ingested.
- Costs are ingested directly or inferred from usage and model prices.
- Supplied costs take precedence.
- Historical calculations remain as calculated at ingestion.
- Cache/reasoning categories must not be double-counted.
- Missing usage/prices produce warnings and remediation paths.

[Cost semantics](https://langfuse.com/docs/observability/features/token-and-cost-tracking)

The public demo route led to account creation rather than an unauthenticated dashboard, so live first-project and network-error states were not verified.

### User feedback

A [launch discussion](https://news.ycombinator.com/item?id=42441258) praised having traces and evaluation scores together. Other reports concern [missing totals in custom ingestion](https://github.com/langfuse/langfuse/issues/7478), [cache-related cost mismatches](https://github.com/langfuse/langfuse/issues/8559), and the need for [average cost per billable feature](https://github.com/orgs/langfuse/discussions/11098).

**Copy:** workflow versus step costs, pricing provenance, actionable missing-cost states.

**Avoid:** making instrumented estimates appear equivalent to complete provider billing.

---

# 3. Menu bar utility research

## Stats, exelban/stats

**Inspected:** [repository](https://github.com/exelban/stats), [menu screenshots](https://cdn.mac-stats.com/assets/images/menus.png), and [expanded panels](https://cdn.mac-stats.com/assets/images/popups.png).

### Useful patterns

- Compact, independently configurable menu bar modules.
- Large immediate readings followed by history, then detailed rows.
- Network upload/download use aligned values and consistent colors.
- CPU/memory detail progressively reveals composition and top consumers.
- Status words accompany measurements: charging, on hold, health, interface.

Stats does not have financial budgets or API authentication. Its relevant analogues are thresholds, local sensor access, missing measurements, and restrained presentation.

### Feedback

- [HN praise](https://news.ycombinator.com/item?id=33778558): sufficient as an iStat replacement for that commenter.
- [Width complaint](https://github.com/exelban/stats/issues/669): widgets disappeared behind long application menus.
- [Contrast/discoverability issue](https://github.com/exelban/stats/issues/2377): a user thought customization had disappeared, then found it in another settings tab.
- [Readability complaint](https://news.ycombinator.com/item?id=42883937): text felt too thin.

**Copy:** direct numbers, aligned rows, quiet hierarchy, configurable width.

**Avoid:** settings that exist but are difficult to discover.

---

## iStat Menus

**Inspected:** [official interface](https://bjango.com/mac/istatmenus/) and [detailed independent review](https://eshop.macsales.com/blog/95542-istat-menus-7-is-the-latest-in-a-long-line-of-delightful-mac-monitoring-apps-from-bjango/).

### Useful patterns

- Highly customizable menu metrics, colors, spacing, and section order.
- Combined view reduces menu bar clutter.
- Historical charts and richer expanded detail.
- Rule-based notifications demonstrate threshold **plus duration**, which helps avoid transient-noise alerts.

Its dense rings, nested cards, and sideways detail panels are less suitable for Meter’s default view.

### Feedback

The [OWC review](https://eshop.macsales.com/blog/95542-istat-menus-7-is-the-latest-in-a-long-line-of-delightful-mac-monitoring-apps-from-bjango/) praises customization and Combined view.

A [2024 Reddit discussion](https://www.reddit.com/r/macapps/comments/1fq2rj1/psa_istat_menus_v7_is_a_ui_downgrade_v6_is_an/) complains about lost chart context, harder time-range switching, oversized indicators, and configuration migration.

A [MacRumors discussion](https://forums.macrumors.com/threads/istat-menus-7-0-brings-comprehensive-redesign-and-new-features.2432615/page-7) includes an accessibility-related complaint that hover-triggered popouts feel chaotic and nauseating. Other participants prefer the richer design.

These are historical version-7 reactions, not proof every current release retains those issues.

**Copy:** Combined view and customization.

**Avoid:** hover cascades, decorative gauges replacing legible values, and removing chart scales in pursuit of visual cleanliness.

---

## CodexBar

**Inspected:** [screenshot](https://github.com/steipete/CodexBar/blob/main/docs/codexbar.png), [UI specification](https://github.com/steipete/CodexBar/blob/main/docs/ui.md), [OpenAI integration](https://github.com/steipete/CodexBar/blob/main/docs/openai.md), and [Claude integration](https://github.com/steipete/CodexBar/blob/main/docs/claude.md).

### What works

- Provider switching with small quota indicators.
- Explicit session and weekly windows.
- Percentage plus reset countdown.
- Pace relative to the reset.
- Separate extra-usage and local-cost sections.
- Direct links to provider dashboards and status pages.
- Tabular digits and configurable compact/detailed presentations.
- Missing values remain unavailable rather than borrowing another window’s value.

Its current docs distinguish the OpenAI API Platform provider from Codex subscription monitoring.

### States and authentication

The UI specification documents retaining last-known usage after a refresh failure, while independently refreshed sections can remain healthy.

Authentication varies by source: Admin API credentials, CLI/OAuth, and optional browser-cookie routes. Cookie/Keychain permissions and background prompting are therefore real product-design concerns, not invisible implementation details.

### Feedback

- [Cost-label confusion](https://github.com/steipete/CodexBar/issues/781): local estimates differed from another surface; labels were clarified.
- [Currency/unit bug](https://github.com/steipete/CodexBar/issues/97): a cents-versus-currency presentation error caused alarm despite a correct percentage.
- [Keychain prompts](https://github.com/steipete/CodexBar/issues/2115): repeated permission prompts frustrated users.
- [Density/performance discussion](https://github.com/steipete/CodexBar/issues/1364): users praised the original lightweight utility but objected to heavier overview content and scope growth. Some performance problems were reported fixed.

**Copy:** labeled windows, reset context, source separation, last-known state.

**Avoid:** putting every supported provider and every chart into the initial popover.

---

## ccusage

**Inspected:** [repository](https://github.com/ccusage/ccusage), [cost modes](https://ccusage.com/guide/cost-modes), and [blocks reports](https://ccusage.com/guide/blocks-reports).

This is primarily a **terminal reporting tool**, not a native menu bar design reference.

### What it contributes

- Daily, monthly, session, project, agent, and model reporting.
- Auditable input/output/cache categories.
- Detailed rows and totals.
- JSON export, timezone controls, and pricing modes.
- Inferred blocks, burn rate, and projections.

Its detailed table is a good model for Meter’s **inspection/export layer**, not the glance view.

### Important caveats

- Local API-equivalent cost is not a subscription bill.
- Inferred block limits are not necessarily authoritative provider allowances.
- Its documented `display` mode can show missing recorded cost as `$0.00`, which Meter should avoid.
- [`blocks --live`](https://ccusage.com/guide/live-monitoring) was removed in version 18; old live-monitor screenshots should not be presented as current functionality.

### Feedback

A [quota mismatch issue](https://github.com/ccusage/ccusage/issues/916) illustrates the mismatch between local token accounting and provider subscription percentages.

**Copy:** auditability and explicit cache categories.

**Avoid:** converting missing financial information into confirmed zero.

---

## Three additional Claude/Codex menu bar apps

### Claude Usage Bar, Blimp Labs

[Repository](https://github.com/Blimp-Labs/claude-usage-bar) · [Screenshot](https://github.com/Blimp-Labs/claude-usage-bar/blob/main/macos/Resources/demo.png)

**Observed:** stacked five-hour/seven-day menu meters; quota bars; reset countdowns; a range selector; two-line quota history; updated age; refresh/sign-out actions.

**Documented:** browser authorization rather than an API key, configurable refresh intervals, per-window notification thresholds, and extra usage.

**Reported problems:**

- [Countdown continues past reset](https://github.com/Blimp-Labs/claude-usage-bar/issues/40)
- [No retained data after launch](https://github.com/Blimp-Labs/claude-usage-bar/issues/42)
- [Near-limit reading gets stuck](https://github.com/Blimp-Labs/claude-usage-bar/issues/45)
- [Request for session versus monthly extra spend](https://github.com/Blimp-Labs/claude-usage-bar/issues/48)

**Lesson:** reset transitions and persisted last-known readings are first-class UX, not edge cases. API/project cost analytics and hard spending enforcement were not established.

### Claude Usage, richhickson

[Repository](https://github.com/richhickson/claudecodeusage) · [Native menu title](https://github.com/richhickson/claudecodeusage/blob/main/docs/style-native.png)

**Observed:** a restrained monochrome bars-plus-percentage title; expanded session, weekly, model-specific, service-status, and update sections.

**Documented:** selectable title metric, local history, extra spend, multi-account support, retry/backoff, and Claude Code Keychain-based OAuth. Some optional features add session hooks and terminal Automation permissions.

A [release repair](https://github.com/richhickson/claudecodeusage/releases/tag/v1.8) addressed endpoint/header/parsing/rate-limit fragility. An [HN report](https://news.ycombinator.com/item?id=46544524) describes “not signed in” confusion for an API-oriented user.

**Lesson:** onboarding must identify whether the user wants API spend, subscription quota, or local usage. One generic “Connect Claude” button is insufficient.

### QuotaBar, softmaxe

[Repository](https://github.com/softmaxe/quota-bar) · [Overview screenshot](https://github.com/softmaxe/quota-bar/blob/main/docs/images/hero.png)

This was the strongest **failure-state and accounting-semantics reference**.

**Observed:**

- Explicit “% left” and reset countdowns.
- Expected-remaining pace markers.
- A separate Local usage section.
- Tokens/cost switching.
- Daily bars, model detail, and cache composition.
- Failed refresh retains quota values, neutralizes their styling, explains the failure, and shows retry timing.
- Signed-out quota still leaves independently available local history visible.

[Failure screenshot](https://github.com/softmaxe/quota-bar/blob/main/docs/images/interactions/refresh-failed.png) · [Signed-out screenshot](https://github.com/softmaxe/quota-bar/blob/main/docs/images/interactions/sign-in.png)

Its documentation distinguishes:

- Confirmed zero
- Not scanned
- Unpriced usage
- No applicable price

It also explicitly calls local costs estimates, not subscription charges.

**Cautions:** screenshots use sample data; independent market validation was not established. Its optional remote-log syncing has broader privacy implications than local aggregate storage.

**Lesson:** copy its state model, not necessarily its whole feature set.

---

# 4. Apple macOS 26 and Liquid Glass

## What Apple actually recommends

<citation refs="Qou4mi6M_4KHtec48O11R">Apple generally recommends that a menu bar extra open a menu unless its functionality is too complex. Extras can disappear when menu bar space is constrained, so essential access should not depend exclusively on their visibility.</citation>

<citation refs="2z85ebsa9S3mwlsl6arZQ">SwiftUI’s MenuBarExtra supports a window style for complex or data-rich content.</citation> This justifies Meter’s chart-and-budget popover-like surface. It does **not** automatically make that surface a full detachable application window.

<citation refs="YO7slVkWvRtaNAxuq-xN0">Standard SwiftUI/AppKit components adopt the new appearance when built appropriately. Apple advises removing custom backgrounds that interfere with native popovers and testing accessibility appearance settings.</citation>

<citation refs="_OInygN6YNSNg7MO--dno">Liquid Glass belongs primarily to the control/navigation layer, not the content layer. Text-heavy surfaces need legibility; clear glass is not the default material for a financial dashboard.</citation>

[Popover guidance](https://developer.apple.com/design/human-interface-guidelines/popovers) emphasizes a few related tasks, avoiding cascades, preserving work on dismissal, and not relying on a transient popover alone to deliver warnings.

<citation refs="QynWFDdBp-sz8ZHghjSWX">Apple’s chart guidance favors meaningful scales, appropriate bar/line choices, readable summaries, keyboard/VoiceOver access, and information that does not depend solely on color or interaction.</citation>

## What this means for Meter

These are **my design interpretations**, not Apple-prescribed dimensions:

- Start around **360 points wide** for the menu surface.
- Use native materials and controls rather than custom blur/glass effects.
- Keep chart content visually stable and readable.
- Put settings, credentials, historical exploration, and complex budget editing in normal windows.
- Respect Reduce Transparency and Reduce Motion.
- Avoid animated digits, permanent pulsing, and hover-only essential controls.
- Make the title and every progress bar understandable to VoiceOver.

---

# 5. The 10 concrete patterns Meter should copy

## 1. Put the accounting basis beside the number

Use **“Provider-reported API cost”**, **“Local estimate”**, or **“Plan allowance.”**

Why: CodexBar, ccusage, and Claude billing feedback all show that a correct number with an ambiguous label still destroys trust.

[CodexBar example](https://github.com/steipete/CodexBar/issues/781) · [Claude example](https://github.com/anthropics/claude-code/issues/67083)

## 2. Show reporting coverage, not just refresh age

Use:

> Data through 14:00 UTC  
> Checked 2 minutes ago

If the provider does not expose a watermark, say that coverage is unknown rather than implying freshness.

Why: Anthropic’s reporting delay can be hours even after a successful fetch.

[Freshness documentation](https://platform.claude.com/docs/en/manage-claude/usage-cost-analytics-api)

## 3. Retain last-known values after failure

Keep the amount, dim affected sections, and show:

> Couldn’t refresh · Last successful reading 18 minutes ago  
> Retry in 90 seconds

Do not erase healthy local history because subscription authentication failed.

Why: QuotaBar demonstrates graceful partial failure exceptionally well.

[Observed reference](https://github.com/softmaxe/quota-bar/blob/main/docs/images/interactions/refresh-failed.png)

## 4. Make scope inseparable from totals

Always attach account, provider, project/workspace, period, timezone, and currency to the analytical context.

Every headline, chart, table, and export should inherit that context unless explicitly labeled otherwise.

Why: OpenAI filter confusion is a recurring support theme.

[Example](https://community.openai.com/t/usage-dashboard-showing-budget-amount-but-no-usage/1366726)

## 5. Follow total → contributor → explanation

Start with spend, then ranked providers/models/projects/keys. Selecting a contributor should preserve the period and other filters.

Why: OpenRouter’s Overview-to-Explore progression makes investigation predictable.

[Reference](https://openrouter.ai/docs/guides/features/activity)

## 6. Use small horizontal budget bars with explicit consequences

Show:

> $128 / $200 · 64% used  
> Alerts only · Resets 1 December UTC

Put provider-enforced caps in a separate row or detail.

Why: this is more space-efficient and less ambiguous than a large ring.

[OpenAI distinction](https://developers.openai.com/api/docs/guides/spend-limits) · [Anthropic inherited limits](https://support.claude.com/en/articles/9796807-create-and-manage-workspaces-in-the-claude-console)

## 7. Use bars for daily spend, lines for cumulative trajectory

- Daily spending: bars, zero baseline.
- Provider composition: restrained stacking.
- Cumulative spending versus budget: actual line plus clearly differentiated forecast.
- Small popover: one compact trend, not four dashboard cards.

Why: the chart should answer one question at its displayed size.

[Apple charts](https://developer.apple.com/design/human-interface-guidelines/charts) · [Anthropic cost page](https://platform.claude.com/cost)

## 8. Pair quota percentage with window and reset

Use:

> Current session · 62% used  
> Resets in 1h 42m

Never show an unlabeled percentage whose window silently changes.

At reset, show **“Reset expected, updating…”** until a fresh reading confirms the new allowance.

[CodexBar UI specification](https://github.com/steipete/CodexBar/blob/main/docs/ui.md) · [Reset bug example](https://github.com/Blimp-Labs/claude-usage-bar/issues/40)

## 9. Keep the menu bar narrow and stable

One selected metric, tabular digits, predictable abbreviation, optional icon-only mode.

Put provider names and secondary figures in the popover.

Why: Stats users encounter real menu competition and notch constraints.

[Width issue](https://github.com/exelban/stats/issues/669)

## 10. Provide an audit trail without making it the default view

A value’s details should expose:

- Source and reporting basis
- Included/excluded accounts
- Cost categories
- Pricing version for estimates
- Cache/reasoning treatment
- Unattributed or unpriced amounts
- Export and provider-dashboard link

Why: Langfuse and Helicone show how ingestion/pricing assumptions affect cost; ccusage demonstrates the value of inspectable detail.

[Langfuse semantics](https://langfuse.com/docs/observability/features/token-and-cost-tracking) · [ccusage modes](https://ccusage.com/guide/cost-modes)

---

# 6. Five anti-patterns to avoid

1. **The ambiguous grand total.**  
   Never sum subscription API-equivalent estimates, gateway estimates, and provider costs. Gateway traffic may already be included in the provider total.

2. **Failure disguised as zero.**  
   Disconnected, delayed, unscanned, unsupported, and no activity need different states.

3. **The dashboard squeezed into a popover.**  
   Avoid rings, multiple legends, many provider tabs, dense tables, and hover cascades. CodexBar’s scope-growth feedback and iStat’s redesign reactions are warnings.

4. **A budget that implies protection it cannot provide.**  
   A local notification is not a kill switch. Even provider/gateway enforcement can overshoot.

5. **Invisible permissions and silent billing-route changes.**  
   Do not unexpectedly read browser cookies, trigger repeated background Keychain prompts, enable extra usage, or fall back from subscription access to paid API traffic.

[Relevant examples: missing cost](https://ccusage.com/guide/cost-modes), [density](https://github.com/steipete/CodexBar/issues/1364), [permissions](https://github.com/steipete/CodexBar/issues/2115), [enforcement](https://developers.cloudflare.com/ai-gateway/features/spend-limits/)

---

# 7. Recommended glance view

## Menu bar title

**Default:** `$12.84 today`

Alternatives in settings:

- `$128.40 MTD`
- Compact amount only
- Icon only
- A selected subscription allowance, explicitly identified in its accessible label

Use one stable metric. Do not automatically alternate between dollars and percentages.

For unavailable data, show an unavailable/attention state, not `$0.00`. For stale data, retain the last amount with an attention indicator and an explanatory accessible label.

## Popover hierarchy

1. **Scope:** all selected API accounts, reporting day/timezone
2. **Headline:** today’s provider-reported cost
3. **Coverage:** partial/delayed reporting where applicable
4. **Provider rows:** amount plus each source’s freshness
5. **One seven-day spend chart**
6. **Monthly target:** amount, percentage, reset, enforcement explanation
7. **Optional collapsed subscription summary**
8. **Open Meter, Refresh, Settings**

**Why this order:** the user gets the financial answer immediately, then its reliability, then its causes and consequences.

The following concept uses illustrative figures, not account data.

```visual
<!doctype html>
<html>
<head>
<title>Meter glance and main-window concepts</title>
<style>
*{box-sizing:border-box}body{font:13px/1.45 var(--font-sans);color:var(--foreground);margin:0}button{font:inherit;cursor:pointer;color:inherit;background:transparent;border:1px solid var(--border);border-radius:7px;padding:7px 12px}button[aria-selected=true]{background:var(--surface-primary);border-color:var(--chart-1)}.switch{display:flex;gap:8px;margin-bottom:12px}.note,.muted{color:var(--muted-foreground);font-size:11px}.note{margin-bottom:16px}h2,h3{margin:0}h2{font-size:24px;letter-spacing:-.02em;font-weight:600}h3{font-size:13px;font-weight:600}.num{font-variant-numeric:tabular-nums}.preview[hidden]{display:none}.menuline{padding:8px 0;border-bottom:1px solid var(--border);display:flex;justify-content:space-between;max-width:360px}.menuval{font-weight:600}.popover{width:min(100%,360px);background:var(--surface-primary);border:1px solid var(--border);border-radius:14px;margin-top:10px;padding:18px}.row{display:flex;justify-content:space-between;gap:12px;align-items:baseline}.divider{border-top:1px solid var(--border);margin:14px 0}.kicker{font-size:11px;color:var(--muted-foreground)}.hero{font-size:32px;font-weight:600;letter-spacing:-.03em;margin:2px 0}.coverage{font-size:11px;color:var(--muted-foreground);padding-bottom:8px}.provider{padding:8px 0}.provider .muted{margin-top:3px}.progress{height:5px;background:var(--muted);border-radius:3px;overflow:hidden;margin:7px 0}.progress span{height:100%;display:block;background:var(--chart-1)}.spendbars{height:62px;display:flex;gap:7px;align-items:end;margin:12px 0 3px}.spendbars i{display:block;flex:1;background:color-mix(in oklab,var(--chart-1) 35%,transparent);border-radius:3px 3px 0 0}.spendbars i:last-child{background:var(--chart-1)}.tinyrow{display:flex;justify-content:space-between;color:var(--muted-foreground);font-size:10px}.foot{display:flex;justify-content:space-between;align-items:center;gap:8px}.foot button{border:0;padding:3px 0;color:var(--chart-1)}.main{border:1px solid var(--border);border-radius:12px;overflow:hidden}.appbar{padding:12px 16px;border-bottom:1px solid var(--border);display:flex;justify-content:space-between;gap:12px}.workspace{display:grid;grid-template-columns:110px minmax(0,1fr)}.sidebar{padding:16px 12px;border-right:1px solid var(--border);font-size:11px;color:var(--muted-foreground)}.sidebar div{padding:7px 4px}.sidebar .selected{color:var(--foreground);background:var(--surface-primary);border-radius:5px}.content{padding:18px;min-width:0}.filterbar{display:flex;gap:6px;flex-wrap:wrap;margin:12px 0 18px}.pill{border:1px solid var(--border);border-radius:5px;padding:4px 7px;font-size:10px}.stats{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:12px;margin-bottom:22px}.stats strong{display:block;font-size:22px;letter-spacing:-.02em;font-weight:600}.chart{height:130px;display:flex;gap:5px;align-items:end;border-bottom:1px solid var(--border);margin:12px 0 4px}.stack{flex:1;display:flex;flex-direction:column;justify-content:end;min-width:3px}.stack i{display:block;background:var(--chart-1)}.stack i+i{background:var(--chart-2)}.legend{font-size:10px;color:var(--muted-foreground);margin-top:9px}.legend b{font-weight:500;color:var(--chart-1)}.legend b:last-child{color:var(--chart-2)}.target{padding:12px 0;margin-top:12px;border-bottom:1px solid var(--border)}.table{width:100%;border-collapse:collapse;margin:12px 0}.table th{font-size:10px;font-weight:500;color:var(--muted-foreground);text-align:left}.table td{font-size:11px;padding:9px 0;border-bottom:1px solid var(--border)}.table td:last-child,.table th:last-child{text-align:right}.status{font-size:10px;line-height:1.7;color:var(--muted-foreground);padding-top:6px}.accent{color:var(--chart-1)}.shell{container-type:inline-size}.annotation{margin-top:12px;font-size:11px;color:var(--muted-foreground);max-width:540px}details{margin-top:22px;font-size:11px;color:var(--muted-foreground)}summary{cursor:pointer}details img{display:block;width:min(100%,280px);margin-top:12px}a{color:var(--chart-1)}
@container(max-width:480px){.workspace{grid-template-columns:1fr}.sidebar{display:flex;gap:7px;flex-wrap:wrap;border-right:0;border-bottom:1px solid var(--border);padding:6px 10px}.sidebar div{padding:4px}.stats strong{font-size:18px}.content{padding:14px}.stats{gap:8px}.appbar{font-size:11px}}
</style>
</head>
<body>
<div class="switch" role="tablist" aria-label="Meter concept">
<button role="tab" aria-selected="true" data-view="glance">Glance view</button>
<button role="tab" aria-selected="false" data-view="window">Main window</button>
</div>
<div class="note">Design recommendation. All numbers and connection states are illustrative.</div>

<section id="glance" class="preview">
<div class="menuline"><span class="muted">macOS menu bar</span><span class="menuval num">$12.84 today</span></div>
<div class="popover">
<div class="row"><h3>Meter</h3><span class="muted">All API accounts · UTC</span></div>
<div class="divider"></div>
<div class="row"><span class="kicker">API spend today</span><span class="muted">Partial reporting</span></div>
<div class="hero num">$12.84</div>
<div class="coverage">Provider-reported cost. Not a final invoice total.</div>
<div class="provider"><div class="row"><strong>Anthropic</strong><span class="num">$8.21</span></div><div class="muted">Data through 05:20 UTC</div></div>
<div class="provider"><div class="row"><strong>OpenAI</strong><span class="num">$4.63</span></div><div class="muted">Fetched 6m ago · provider lag unknown</div></div>
<div class="spendbars" aria-label="Illustrative seven-day spend">
<i style="height:33%"></i><i style="height:48%"></i><i style="height:36%"></i><i style="height:68%"></i><i style="height:54%"></i><i style="height:83%"></i><i style="height:65%"></i>
</div>
<div class="tinyrow"><span>Nov 7</span><span>7 days · daily API cost</span><span>Today</span></div>
<div class="divider"></div>
<div class="row"><h3>Monthly alert target</h3><span class="num">$128.40 / $200</span></div>
<div class="progress"><span style="width:64.2%"></span></div>
<div class="muted">64% used · Alerts only, does not stop requests</div>
<div class="divider"></div>
<div class="row"><h3>Plan allowance</h3><span class="muted">Optional pinned summary</span></div>
<div class="row" style="margin-top:8px"><span>Claude · current session</span><span class="num">62% used</span></div>
<div class="progress"><span style="width:62%"></span></div>
<div class="muted">Resets in 1h 42m · Not API spend</div>
<div class="divider"></div>
<div class="foot"><button onclick="pick('window')">Open Meter</button><span class="muted">Refresh · Settings</span></div>
</div>
<p class="annotation">One financial answer first. Per-source freshness stays visible. Subscription allowance uses a separate section and unit.</p>
</section>

<section id="window" class="preview shell" hidden>
<div class="main">
<div class="appbar"><strong>Meter · API spend</strong><span class="muted">All accounts · November 2026 · USD · UTC</span></div>
<div class="workspace">
<nav class="sidebar"><div class="selected">Overview</div><div>Breakdowns</div><div>Plan usage</div><div>Budgets & alerts</div><div>Connections</div></nav>
<div class="content">
<h2>Overview</h2>
<div class="filterbar"><span class="pill">All providers</span><span class="pill">All projects / workspaces</span><span class="pill">Nov 1–13</span><span class="pill">Clear filters</span></div>
<div class="stats num">
<div><span class="kicker">Reported month to date</span><strong>$128.40</strong><span class="muted">Partial · mixed freshness</span></div>
<div><span class="kicker">Alert target used</span><strong>64%</strong><span class="muted">$200 monthly target</span></div>
<div><span class="kicker">Projected month end</span><strong>~$296</strong><span class="muted">Linear pace · provisional</span></div>
</div>
<div class="row"><h3>Daily API cost</h3><span class="muted">By provider · Chart / Table</span></div>
<div class="chart" aria-label="Illustrative daily cost by provider">
<div class="stack" style="height:28%"><i style="height:64%"></i><i style="height:36%"></i></div>
<div class="stack" style="height:37%"><i style="height:64%"></i><i style="height:36%"></i></div>
<div class="stack" style="height:24%"><i style="height:64%"></i><i style="height:36%"></i></div>
<div class="stack" style="height:43%"><i style="height:64%"></i><i style="height:36%"></i></div>
<div class="stack" style="height:50%"><i style="height:64%"></i><i style="height:36%"></i></div>
<div class="stack" style="height:33%"><i style="height:64%"></i><i style="height:36%"></i></div>
<div class="stack" style="height:61%"><i style="height:64%"></i><i style="height:36%"></i></div>
<div class="stack" style="height:46%"><i style="height:64%"></i><i style="height:36%"></i></div>
<div class="stack" style="height:75%"><i style="height:64%"></i><i style="height:36%"></i></div>
<div class="stack" style="height:58%"><i style="height:64%"></i><i style="height:36%"></i></div>
<div class="stack" style="height:81%"><i style="height:64%"></i><i style="height:36%"></i></div>
<div class="stack" style="height:94%"><i style="height:64%"></i><i style="height:36%"></i></div>
<div class="stack" style="height:74%"><i style="height:64%"></i><i style="height:36%"></i></div>
</div>
<div class="tinyrow"><span>Nov 1</span><span>Nov 7</span><span>Nov 13 · partial</span></div>
<div class="legend"><b>Anthropic</b> + <b>OpenAI</b> · Missing coverage is not a confirmed zero.</div>
<div class="target">
<div class="row"><h3>Monthly target · alerts only</h3><span class="num">$128.40 / $200</span></div>
<div class="progress"><span style="width:64.2%"></span></div>
<div class="muted">Current pace exceeds target. Provider hard limits are managed separately.</div>
</div>
<div class="filterbar" style="margin-bottom:0"><span class="pill">Models</span><span class="pill">Projects</span><span class="pill">Keys</span><span class="pill">Days</span></div>
<table class="table num"><thead><tr><th>Model / charge type</th><th>Share</th><th>Reported cost</th></tr></thead><tbody>
<tr><td>Claude Sonnet</td><td>48%</td><td>$61.63</td></tr>
<tr><td>OpenAI models</td><td>36%</td><td>$46.22</td></tr>
<tr><td>Other models & tools</td><td>16%</td><td>$20.55</td></tr>
</tbody></table>
<div class="status">Anthropic: data through 05:20 UTC · OpenAI: fetched 6m ago<br>Coverage: selected accounts only · <span class="accent">View sources, estimates & reconciliation</span></div>
</div>
</div>
</div>
<p class="annotation">Analysis belongs in a normal, resizable window. Scope, reporting basis, and coverage remain attached to every breakdown.</p>
</section>

<details>
<summary>Inspected reference: QuotaBar’s failed-refresh state</summary>
<!-- local screenshot from the research session, not included -->
<p>Published sample-data screenshot. <a href="https://github.com/softmaxe/quota-bar/blob/main/docs/images/interactions/refresh-failed.png">Original source</a></p>
</details>
<script>
function pick(id){
document.querySelectorAll('.preview').forEach(x=>x.hidden=x.id!==id);
document.querySelectorAll('[data-view]').forEach(x=>x.setAttribute('aria-selected',String(x.dataset.view===id)));
}
document.querySelectorAll('[data-view]').forEach(x=>x.onclick=()=>pick(x.dataset.view));
</script>
</body>
</html>
```

---

# 8. Recommended main window

Use a normal, resizable native window, initially around **960 × 680 points**. That size is a starting design choice, not an Apple requirement.

## Navigation

- **Overview**
- **Breakdowns**
- **Plan usage**
- **Budgets & alerts**
- **Connections**

## Overview

**Persistent scope bar:** provider/account, project/workspace, period, timezone, currency.

**Three primary figures:**

1. Reported month-to-date cost
2. Budget remaining or target used
3. Projected month-end cost, only when coverage supports a useful forecast

**Main chart:** daily spend, initially by provider. Offer model grouping, a cumulative view, and table mode.

**Below:** ranked contributors with dollars first, then share, comparable-period change, and optional unit metrics.

Do not put a cumulative budget line against daily bars on the same scale. Use a separate cumulative view or budget progress component.

## Breakdowns

Provide Models, Projects/Workspaces, Keys, and Days. Add users/features only where the connected source actually supplies them.

Each row should reveal:

- Cost and share
- Requests/tokens where meaningful
- Cache/reasoning/tool components
- Source and pricing basis
- Coverage gaps
- Matching provider-dashboard link

Keep **Unattributed**, **Other charges**, and **Unpriced** visible rather than dropping them.

## Plan usage

Separate provider/account sections with:

- Window name
- Explicit used or remaining percentage
- Reset time
- Additional weekly/model constraints
- Extra usage as a separate financial row
- Source freshness

Do not extrapolate local tokens into authoritative subscription percentages.

## Budgets & alerts

For every rule show:

- Scope and period
- Threshold and currency
- Notification destination
- Whether requests continue or stop
- Reset behavior
- Last trigger and recovery
- Data delay caveat

## Connections

Make connection health a sequence, not one green checkmark:

1. Credential accepted
2. Correct organization/project/region
3. Reporting permission available
4. First data received
5. Coverage understood

Explain elevated credentials before requesting them. Keep credential repair in persistent onboarding/settings, not a dismissible popover.

---

# 9. Required state vocabulary

Meter should ship with these states designed and tested:

- **No usage:** confirmed zero within a known, covered interval.
- **Waiting for reporting:** connected, but the provider has not reported the interval.
- **Partial:** some accounts, periods, categories, or sources are missing.
- **Stale:** retain the last successful value with its age.
- **Disconnected:** reconnect action, not a zero figure.
- **Insufficient permission:** name the required role/key type.
- **Unpriced:** usage exists but no reliable price is available.
- **Unavailable breakdown:** the source cannot provide that dimension.
- **Limit reached:** distinguish subscription allowance, financial cap, and request/token rate limit.
- **Reset pending:** countdown ended, fresh allowance not yet confirmed.

These are the difference between a pretty meter and one users will trust.

## Bottom line

For Meter, I would combine:

- **Stats’ quiet hierarchy**
- **OpenRouter’s contributor drilldown**
- **Anthropic’s reporting watermark**
- **CodexBar’s explicit usage windows**
- **QuotaBar’s failure-state semantics**
- **Apple’s native materials and restrained interaction**

The defining feature should not be another chart. It should be that **every displayed number has an obvious meaning, scope, age, and consequence**.