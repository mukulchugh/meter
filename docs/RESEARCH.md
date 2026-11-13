# Meter research: Anthropic and OpenAI spend APIs, sign-in, Keychain, prior art

All facts below were read from the cited page on **2026-11-13** (the "checked" date for every row unless a row says otherwise). Nothing was called with a real key. No `.env` or secrets were read.

Source notes:
- Anthropic docs: `docs.anthropic.com/en/...md` redirects to the canonical host `platform.claude.com/docs/en/...`. URLs below use the canonical host. The `.md` suffix works on every page used.
- OpenAI: `platform.openai.com` returns HTTP 403 to scripted fetches. Used instead: `developers.openai.com/...md` (works) and the OpenAPI spec `openai/openai-openapi`, `openapi.yaml`, spec `info.version` 2.3.0, repo head commit `995168c133dfc4f430a66fce08bdc3f4cd58cb82` (2026-11-13T02:53Z). The `gh api ... contents/openapi.yaml` call returned 0 bytes (file is 4.3 MB, over the contents API limit), so the file was fetched from `raw.githubusercontent.com/openai/openai-openapi/master/openapi.yaml`. Line numbers cited are in that copy.
- OpenAI terms of use (`openai.com/policies/*`) returned 403. Anything about OpenAI terms is therefore **unverified**.

---

## 0. Headline findings

1. **Prior notes: confirmed or changed**

| Prior note (Aug 2026) | Status on 2026-11-13 |
|---|---|
| Anthropic `GET /v1/organizations/cost_report` with `sk-ant-admin01-` key | **Confirmed but now "Legacy".** Still supported. Anthropic says new integrations should use `GET /v1/organizations/analytics/cost` (beta). |
| Anthropic `amount` is cents as decimal string, daily buckets, `has_more`/`next_page` | Confirmed for legacy. New endpoint: cents as decimal string with six decimals (`"41280.000000"`), rows not buckets. |
| Anthropic `usage_report/messages` exists | Confirmed (legacy). New equivalent is `/v1/organizations/analytics/usage`. |
| OpenAI `GET /v1/organization/costs`, admin key `sk-admin-...`, `start_time` required | Confirmed in spec. "Org owners only" is **not stated** in the sources read, see section 1.2. |
| OpenAI `amount` is `{value, currency}` in dollars | Confirmed (`value` number, `currency` lowercase `"usd"`). |
| OpenAI usage split per family `/v1/organization/usage/*` | Confirmed, 10 families. |
| Gemini has no admin cost API | **Partly verified.** The Gemini API billing guide only points to the AI Studio Usage dashboard. No cost API is mentioned. Cloud Billing export was not checked. |

2. **Hard gate:** The Anthropic Admin API is **not available to individual Console accounts or claude.ai Team plans**. The user must have a Console organization and the admin role (Console accounts can set one up on the Organization page). Source: https://platform.claude.com/docs/en/manage-claude/admin-api (Availability).
3. **There is no "sign in with your account" path** that reads spend, for either vendor (section 12). The only official non-key route is Anthropic's `org:admin` OAuth bearer token, issued through Anthropic's own `ant` CLI.
4. **Existing tool overlap is large.** CodexBar (MIT, 23k stars, active) already calls both vendors' admin cost endpoints (section 10). Meter's gap is narrow.
5. **Keychain:** the brief's suggested `kSecAttrAccessible` approach does not apply to an ad-hoc-signed Mac app (section 11).

---

## 1. Keys

### 1.1 Anthropic

| Item | Answer | Source |
|---|---|---|
| Key type | Admin API key | https://platform.claude.com/docs/en/manage-claude/admin-api-keys |
| Prefix | `sk-ant-admin01-...` | same |
| Who creates | Console org members with the **admin** role (owners and primary owners have all admin permissions) | same; https://platform.claude.com/docs/en/manage-claude/admin-api (roles table) |
| Where | Claude Console, `platform.claude.com/settings/admin-keys`, **Create admin key**, name it, pick an expiration, **Add**. Secret shown once. | admin-api-keys |
| Scopes | **None selectable.** "Claude Console keys do not have selectable scopes; every key carries full access to all endpoints that accept Admin API keys" (members, invites, workspaces, API keys, etc.). | admin-api-keys |
| Read-only or narrower key | **None.** "Finer-grained scopes (by resource, or read versus write) are not available." An Admin credential is full-org. | https://platform.claude.com/docs/en/manage-claude/wif-reference (OAuth scopes) |
| Other accepted credentials | (a) OAuth bearer with `org:admin` scope in `authorization: Bearer`, (b) a personal or service-account key not scoped to a workspace (same permissions as the linked account). Usage, cost and Claude Code endpoints all accept these. | https://platform.claude.com/docs/en/manage-claude/usage-cost-api (Check box) |
| Billing-role member | Role table says "billing: can use playground and manage billing details". Whether a billing-role personal key can call cost endpoints is **not documented**. Spike needed with a real org. | admin-api (roles table) |
| Expiration | Preset 3h, 1d, 7d, 30d, custom, or Never. Org policy may cap it. Email warnings at 7d or 1d before expiry (keys with long lifetimes). | https://platform.claude.com/docs/en/manage-claude/authentication (Key expiration) |
| Revoke | Console. For regular API keys, **Disable** is reversible and **Delete** is permanent (archived). The pages read do not separately describe revoking an *admin* key; the admin-keys page is where it is created and listed. Admin API cannot create keys, only read, rename and change status of existing keys. | authentication; admin-api FAQ |
| Enterprise (claude.ai) orgs | Different key: `sk-ant-api01-...` created in claude.ai by the primary owner, scopes selectable (`read:analytics` for the Usage and Cost Analytics API). | admin-api-keys |
| Other | Optional IP allowlisting limits where a leaked key works. | authentication |

### 1.2 OpenAI

| Item | Answer | Source |
|---|---|---|
| Key type | Admin API key. "Admin API keys cannot be used for non-administration endpoints." Costs and usage endpoints use `AdminApiKeyAuth` in the spec. | https://developers.openai.com/api/reference/administration/overview.md ; spec `/organization/costs` L12085 |
| Prefix | `sk-admin-...` (spec examples `sk-admin-1234abcd`, redacted `sk-admin...xyz`) | spec L41377, L11148 |
| Where | `platform.openai.com/settings/organization/admin-keys` | https://developers.openai.com/api/reference/overview.md |
| Who | The create-response example shows `owner.role: "owner"`. The RBAC page lists "Organization Admin: manage organization users, projects, invites, admin API keys, rate limits" with Read/Write for **Org owner** only (not Org reader). So owner-level permission is implied, but no page says "only owners can create". | https://developers.openai.com/api/docs/guides/rbac.md |
| Scopes | None. Create body is only `name` and `expires_in_seconds` (1 to 31,536,000, omit for no expiry). | https://developers.openai.com/api/reference/resources/admin/subresources/organization/subresources/admin_api_keys.md |
| Read-only or narrower | **Not documented for costs or usage.** Scopes such as `api.all.read` exist only for **project** keys (spec L14274) and project keys cannot call admin endpoints. RBAC has a custom-role-eligible permission "Usage: view usage dashboard and export" (Read), which governs the dashboard; whether it can be attached to an admin key is not documented. Spike needed. | rbac.md; spec L14230-14363 |
| Programmatic key minting | `POST /v1/organization/admin_api_keys` exists, but it needs an existing admin key. So it cannot bootstrap from a login. | spec L11006-11175 |
| Revoke | `DELETE /v1/organization/admin_api_keys/{key_id}` (needs an admin key) or the dashboard admin-keys page. `GET` list shows `last_used_at`, `expires_at`, `redacted_value`. | spec L11175-11300 |
| Short-lived alternative | Workload identity federation gives short-lived tokens, but they map to a **project service account**, not an org admin. Not useful for org costs. | https://developers.openai.com/api/docs/guides/workload-identity-federation.md |

---

## 2. Cost endpoints

### 2.1 Anthropic: two APIs, a real trade-off

| | Legacy `GET /v1/organizations/cost_report` | New `GET /v1/organizations/analytics/cost` (beta) |
|---|---|---|
| Status | "Legacy... remains supported" | Recommended for new integrations; **beta**, needs `anthropic-beta: analytics-usage-cost-2026-08-24` |
| Freshness | "typically within 5 minutes of API request completion, though delays might occasionally be longer" | "typically refreshes within 4 hours... can take up to 24 hours"; `data_refreshed_at` timestamp on every response |
| History | No range limit stated (paged by bucket) | `starting_at` within last **365 days** and not before **2026-01-01**; max **31 days** per request |
| Buckets | `1d` only | `1d`, `1h`, `1m` (`1m` max 24h per request) or none (one row per group over whole range) |
| `group_by` | `workspace_id`, `description` only | up to 5 of: `actor`, `actor_type`, `api_key_id`, `workspace_id`, `model`, `service_tier`, `context_window`, `inference_geo`, `speed`, `product`, `agent_id`, `environment_id`, `deployment_id`, `session_id`, `user_profile_id`, `claude_tag_*`, `slack_channel_id`, `rbac_group_id`, `organization_id`; plus `cost_type`, `token_type` which do not count toward the 5 |
| Filters | none documented besides range | `models[]`, `workspace_ids[]`, `api_key_ids[]`, `actor_ids[]`, `actor_types[]`, `service_tiers[]`, `products[]` (includes `claude_code`, `messages_api`, `message_batches_api`, ...), `speeds[]`, `context_windows[]`, `inference_geos[]`, up to 100 values each |
| Paging | `limit` = buckets, default 7, max 31; `page` cursor | `limit` = rows, default 20, max 1000; `page` cursor bound to the query (changing params mid-sequence returns 400); `order_by` `amount`/`list_amount`/`time`, `order` |
| Amount | `amount` string, "lowest currency units (e.g. cents)", `"123.45"` = $1.23; `currency` always `"USD"` | `cost.amount` post-discount, **pre-credit**; `cost.list_amount` pre-discount; decimal string, cents, 6 decimals; `requests` |
| Per-API-key cost | **No** (only by workspace or description string) | **Yes** (`api_key_id`, `actor`) |
| Per-model cost | Via `description` (parsed fields `model`, `service_tier`, `token_type`, ...) | `model` dimension, structured. No `description`. |

Sources: https://platform.claude.com/docs/en/api/beta/organization/cost_report/retrieve ; https://platform.claude.com/docs/en/manage-claude/usage-cost-api ; https://platform.claude.com/docs/en/api/beta/organization/analytics/cost/list ; https://platform.claude.com/docs/en/manage-claude/usage-cost-analytics-api (including its "Migrate" table).

**Legacy response (official example, abbreviated):**
```json
{"data":[{"starting_at":"2025-08-01T00:00:00Z","ending_at":"2025-08-02T00:00:00Z",
  "results":[{"amount":"123.78912","currency":"USD","cost_type":"tokens",
  "description":"Claude Opus 5.5 Usage - Input Tokens","model":"claude-opus-5-5",
  "service_tier":"standard","context_window":"0-200k","inference_geo":"global","speed":"standard",
  "token_type":"cache_creation.ephemeral_1h_input_tokens","workspace_id":"wrkspc_01JwQvzr7rXLA5AGx3HKfFUJ"}]}],
 "has_more":true,"next_page":"page_MjAyNS0wNS0xNFQwMDowMDowMFo="}
```
Buckets are oldest first and include empty days (`results: []`). Grouped fields are `null` unless grouped (non-token costs have null model etc.). `cost_type` values: `tokens`, `web_search`, `code_execution`, `session_usage`.

**New response (official example from the guide):**
```json
{"starting_at":"2026-09-01T00:00:00Z","ending_at":"2026-10-01T00:00:00Z",
 "group":{"model":"claude-opus-5","cost_type":"tokens","token_type":"cache_read_input_tokens", "...":null},
 "cost":{"currency":"USD","amount":"41280.000000","list_amount":"51600.000000","requests":null}}
```
Envelope: `{"data":[rows],"has_more":bool,"next_page":str|null,"data_refreshed_at":"..."}`. Empty buckets produce no rows (client must zero-fill).

Request headers for both: `x-api-key` (or `authorization: Bearer` for OAuth), `anthropic-version: 2026-10-21` (value used in current docs), plus the beta header for the new API. A `User-Agent: YourApp/1.0.0 (https://...)` is recommended by Anthropic for integrations.

### 2.2 OpenAI `GET /v1/organization/costs`

Spec: `openapi.yaml` L12085-12240 (`operationId: usage-costs`). Docs index: https://developers.openai.com/api/reference/overview.md.

| Param | Detail |
|---|---|
| `start_time` | **required**, unix seconds, inclusive |
| `end_time` | unix seconds, exclusive |
| `bucket_width` | only `1d` |
| `project_ids[]`, `api_key_ids[]`, `line_items[]` | filters (`line_items` must match the full string, e.g. `gpt-6-astra, input_tokens`) |
| `group_by[]` | `project_id`, `user_id`, `line_item`, `api_key_id`, `api_source` (`user_id` combos may return 400; `api_source` yields `agents_api` or `unlabeled`) |
| `limit` | buckets, 1 to **180**, default 7 |
| `page` | cursor from `next_page` |

Response (official example, spec L12206 ff.):
```json
{"object":"page","data":[{"object":"bucket","start_time":1730419200,"end_time":1730505600,
 "results":[{"object":"organization.costs.result","amount":{"value":0.06,"currency":"usd"},
  "line_item":null,"project_id":null,"api_key_id":null,"quantity":null,"quantity_unit":null}]}],
 "has_more":false,"next_page":null}
```
- Amount: **dollars as a JSON number** (float), currency lowercase ISO 4217. `1730419200` is exactly midnight UTC (86400 x 20028), so buckets are UTC-day aligned (inferred from the example).
- No `model` dimension on costs. Per-model cost comes from `line_item` (strings like model name plus token kind). `quantity` and `quantity_unit` (`tokens`, `1000_tokens`, `duration_seconds`, `images`, `characters`, ...) appear only when grouped by `line_item`.
- **History depth and freshness: not documented** in the spec, `administration/overview`, or `admin-apis` guide. Treat as unknown and measure with a real key.

---

## 3. Usage (token) endpoints

| | Anthropic | OpenAI |
|---|---|---|
| Endpoint | Legacy `GET /v1/organizations/usage_report/messages`; new `GET /v1/organizations/analytics/usage` | `GET /v1/organization/usage/{completions,embeddings,moderations,images,audio_speeches,audio_transcriptions,vector_stores,code_interpreter_sessions,file_search_calls,web_search_calls}` |
| Buckets | `1m`, `1h`, `1d` (legacy limits: 1m default 60 max 1440; 1h 24/168; 1d 7/31) | `1m`, `1h`, `1d` (same limits as legacy Anthropic, spec L18150) |
| Tokens | `uncached_input_tokens`, `cache_creation.{ephemeral_5m,ephemeral_1h}_input_tokens`, `cache_read_input_tokens`, `output_tokens`, `server_tool_use.web_search_requests`, `requests` (new), `total_tokens` (new) | completions: `input_tokens`, `input_cached_tokens`, `input_cache_write_tokens` (30m and 12h), `input_uncached_tokens`, `output_tokens`, text/audio/image splits, `num_model_requests` |
| Group/filter | Legacy `group_by`: `api_key_id`, `workspace_id`, `model`, `service_tier`, `context_window`, `inference_geo`, `speed`, plus account ids. New adds `actor`, `product`, etc. | completions `group_by`: `project_id`, `user_id`, `api_key_id`, `model`, `batch`, `service_tier`, `api_source`; filters `project_ids`, `user_ids`, `api_key_ids`, `models`, `batch` |
| Adds beyond cost | Token counts by model and key, cache hit analysis, request counts, **Priority Tier** (cost endpoint shows zero token cost for priority commitments; usage shows `service_tier: priority`) | Token counts per model, per key, per project; costs do not group by model, so usage is how to get per-model **tokens** |

**Can cost be computed from usage?** Not reliably. Anthropic: legacy cost cannot split by key, but legacy usage can, so per-key cost would need local price tables (fragile, ignores discounts); the new cost endpoint already splits by `api_key_id`, `model`, `workspace_id` and `token_type`, so **use it instead of computing**. OpenAI: cost supports `api_key_id` and `project_id` and `line_item` directly, so no computation is needed. Use usage only for token counts and request counts.

Sources: usage-cost-api page; https://platform.claude.com/docs/en/api/beta/organization/usage_report/retrieve_messages ; spec L18074-18255 and `UsageCompletionsResult` L79956.

---

## 4. Rate limits and polling cadence

| Vendor | What is documented | Recommended Meter cadence |
|---|---|---|
| Anthropic legacy Usage and Cost API | "The API supports polling once per minute for sustained use. For short bursts (for example, downloading paginated data), more frequent polling is acceptable." Data appears in ~5 min. (usage-cost-api FAQ) | Foreground refresh every 5 min, background 15 min. Backfill in bursts. |
| Anthropic new Analytics API (Console orgs) | **No Console rate limit stated.** The "60 requests per minute per organization across all endpoints" text is on the **Enterprise Analytics API** page (https://platform.claude.com/docs/en/manage-claude/analytics-api) and its migration note. Do not assume it applies to Console. Data lags 4 to 24 h, so polling faster than hourly is useless. | Hourly, plus on app launch and manual refresh. |
| Claude Code Analytics | "up to a 1-hour delay" | Hourly. |
| OpenAI admin endpoints | **Not documented** in the sources read. Spec defines a shared `429` response with an optional `Retry-After` header (spec L124152). | 15 min default, honour `Retry-After`, exponential backoff, floor 5 min. |

Poll only the open window: today and the last 2 days refresh every cycle, older days only on a daily revision pass (Anthropic Analytics values can be revised until about 7 days after month end).

---

## 5. Names (workspaces, projects, keys)

| Need | Anthropic | OpenAI |
|---|---|---|
| Workspaces / projects | `GET /v1/organizations/workspaces` (fields `id`, `name`, `display_color`, `archived_at`, ...). `limit` 1 to 1000, `after_id`. **Default workspace is omitted unless `include_default=true`**; new analytics API returns the default workspace's real id, legacy returns `workspace_id: null` for it. Ref: https://platform.claude.com/docs/en/api/organization/workspaces/list | `GET /v1/organization/projects` (limit 1 to 100, `after`, `include_archived`); spec L13684 |
| API keys | `GET /v1/organizations/api_keys` (`id`, `name`, `partial_key_hint`, `status`, `workspace_id` via `scope`, `principal` user or service account, `expires_at`). Filters `workspace_id`, `status`, `created_by_user_id`. Ref: https://platform.claude.com/docs/en/api/organization/api_keys/list | **Per project:** `GET /v1/organization/projects/{project_id}/api_keys` (`name`, `redacted_value`, owner); spec L13971. Admin keys: `GET /v1/organization/admin_api_keys`. No single org-wide project-key list in the spec paths. |
| Users | `GET /v1/organizations/users` (email, role) for resolving `actor.user_id` | `GET /v1/organization/users` |
| Gotcha | Playground usage has `api_key_id: null`. Anthropic-managed service accounts (`svac_...`) for some Managed Agents sessions are not in your service account list. | Deleted keys or projects: names no longer resolvable, keep a local name cache. |

Cache names locally; refresh daily.

---

## 6. Claude Code and agent analytics

**Endpoint:** `GET /v1/organizations/usage_report/claude_code` (Admin credential, Console orgs). Doc: https://platform.claude.com/docs/en/manage-claude/claude-code-analytics-api ; reference https://platform.claude.com/docs/en/api/beta/organization/usage_report/retrieve_claude_code.

- Params: `starting_at` (UTC `YYYY-MM-DD`, **single day**), `limit` (default 20, max 1000), `page`.
- One record per actor and day and combination of `terminal_type`, `customer_type` (`api` or `subscription`), `subscription_type`, `is_remote`. Sum an actor's records for the day.
- Actor: `{type:"user_actor", email_address}` or `{type:"api_actor", api_key_name}` (this one gives a key **name** directly).
- Metrics: `num_sessions`, `lines_of_code.{added,removed}`, `commits_by_claude_code`, `pull_requests_by_claude_code`, tool accept/reject counts (Edit, MultiEdit, Write, NotebookEdit), and per-model `tokens.{input,output,cache_read,cache_creation}` and `estimated_cost.{amount (cents USD), currency}`.
- Freshness: up to 1 hour. Covers only usage authenticated against the Console org (not Pro/Max personal logins).
- Alternative for cost: new cost endpoint with `products[]=claude_code&group_by[]=actor` (per-user cost).
- OpenAI: no Codex or agent analytics under the org admin endpoints in the spec paths listed (`api_source` grouping separates `agents_api` activity only).

---

## 7. Budgets, spend limits, credit balance

| | Readable by API? |
|---|---|
| Anthropic Console org spend limits (per workspace, monthly, with alert thresholds) | **No documented endpoint.** Set in Console > Workspaces > Spend limits; cannot be set on the Default Workspace. (https://platform.claude.com/docs/en/manage-claude/workspaces) A beta flag `spend-limit-reads-2026-09-26` appears in the `anthropic-beta` enum but no Console endpoint using it was found in the docs read. Treat as **console-only**, revisit. |
| Anthropic Enterprise (claude.ai) per-member monthly spend limits | **Yes**, Spend Limits API, key scope `read:spend_limits`, `GET /v1/organizations/spend_limits/effective` returns effective limit and `period_to_date_spend`. Enterprise only, not Console. (https://platform.claude.com/docs/en/manage-claude/spend-limits-api) |
| Anthropic prepaid credit balance | **No endpoint found** (no "balance" in the Admin API docs read). |
| OpenAI org hard spend limit | **Yes.** `GET /v1/organization/spend_limit` returns `{object:"organization.spend_limit", threshold_amount (integer **cents**), currency:"USD", interval:"month", enforcement:{status:"enforcing"}}`; **404 if none set**. Spec L30090. |
| OpenAI project hard spend limit | **Yes.** `GET /v1/organization/projects/{project_id}/spend_limit`, same shape, 404 if none. Spec L30231. |
| OpenAI spend alerts | **Yes.** `GET /v1/organization/spend_alerts` (and per project): `threshold_amount` integer cents, `interval: month`, `notification_channel` (email recipients). Spec L17305. Alerts are notifications; limits are enforced with HTTP 429 `organization_spend_limit_exceeded`. (https://developers.openai.com/api/docs/guides/spend-limits.md) |
| OpenAI prepaid credit balance | **No endpoint in the current spec.** CodexBar falls back to a legacy `dashboard/billing/credit_grants` URL that it itself describes as "not part of OpenAI's current public API reference". Do not use. |

So: month-to-date spend vs a **user-defined local budget** works for both. Reading the vendor's own limit works for OpenAI only.

---

## 8. Gotchas

| Topic | Anthropic | OpenAI |
|---|---|---|
| Timezone | UTC buckets; ranges snap down to UTC minute, hour or day boundary | UTC-aligned (inferred from the example timestamp); not stated in text |
| Current day | Legacy: partial and mostly fresh in 5 min. New: `data_refreshed_at` says how far data is complete, "usage after that time is missing or partial". Only trust a day once `data_refreshed_at` is past its end. | Partial current-day bucket; delay not documented |
| Revisions | New API values can change until ~7 days after month end ("October 1 values can change until about November 7") | Not documented |
| Rounding | Legacy: fractional cents as decimal string. New: 6 decimals. Parse as decimal, not float; docs warn about float for large values | `value` is a JSON float in dollars; round at display, store as integer micro-dollars |
| Credits, refunds, negative lines | Cost `amount` is "after discounts and before any credits are applied", so credits are **not** in the data and cost will not match the invoice net of credits. Negative lines are not mentioned. | Not documented. Do not assume the sum equals the invoice. |
| Excluded costs | Priority Tier commitment fee not in the data; priority requests show zero token cost in cost endpoint and appear in usage. Legacy cost omits Priority Tier. | Scale Tier not mentioned in costs |
| Nulls | Grouped dimensions are null when not grouped or not applicable; default workspace null in legacy | Same pattern (`project_id: null` when not grouped) |
| Lists | Legacy returns empty buckets, new returns none | Buckets always returned |
| Platform variants | Claude Platform on AWS: legacy endpoints unavailable, Analytics available with AWS auth. Google Cloud (Anthropic managed): only usage endpoint on legacy. Out of scope for v1. | |

---

## 9. Gemini (brief)

The Gemini API billing guide says usage is monitored in Google AI Studio (Dashboard > Usage) and describes prepay/postpay credits. It documents no cost or usage API. https://ai.google.dev/gemini-api/docs/billing.md (checked 2026-11-13). Google Cloud Billing export to BigQuery was not researched. **Out of scope for v1.**

---

## 10. Existing tools

All figures from GitHub API on 2026-11-13.

| Tool | What it does | Licence | Local-only | Both providers' API spend | Notes |
|---|---|---|---|---|---|
| **CodexBar** `steipete/CodexBar` v0.84.0 (2026-11-07), 23.1k stars | macOS 14+ menu bar (and CLI, Linux) for 40+ providers: limits, credits, spend. **OpenAI:** Admin key, calls `/organization/costs` and `/organization/usage/completions`, daily buckets grouped by `line_item` and `model`, optional project filter. **Anthropic:** Admin key, calls legacy `/cost_report` and `/usage_report/messages`, 30 day chart, optional per-workspace spend. Also Codex and Claude subscription limits. | MIT | Yes (no server) | **Yes, both** | Admin keys stored in `~/.config/codexbar/config.json` (legacy `~/.codexbar/config.json`) "with restrictive config-file permissions", **not Keychain**. Also reuses Claude Code OAuth, browser cookies and CLI scraping, which is the ToS-fragile surface (section 12). Docs show no per-API-key breakdown, no budget alerts, no 365-day local history for the admin sources (30 day chart). Contributions: VISION.md says new features and changes to "provider auth, data storage" need owner sign-off. |
| **ccusage** `ccusage/ccusage` (19.4k stars) | CLI that reads **local** Claude Code (and other agent) JSONL logs for token and estimated cost | MIT (LICENSE file) | Yes | No (local logs of agent CLIs only) | Does not see API-key usage from apps or servers. Complements, does not replace. |
| Menu bar wrappers over ccusage (`kenn-io/vibepulse`, `Nihondo/AgentLimits`) | Same local logs in a widget | MIT | Yes | No | Not org-wide spend. |
| **Helicone** `Helicone/helicone` (6.3k stars) | Open source LLM observability proxy and gateway | Apache-2.0 | Self-hostable, needs routing traffic through it | Yes via proxy | Requires changing app base URLs. Not an admin-key reader. |
| **Langfuse** (37k stars), **LiteLLM** (63k stars) | Tracing/gateway platforms | GitHub reports "NOASSERTION" (mixed core plus enterprise directories) | Self-hostable | Via instrumentation | Server product. Wrong shape. |
| Vendor dashboards | Anthropic Console Usage and Cost pages; OpenAI Usage dashboard | n/a | n/a | One each | Not in the menu bar, no cross-vendor view. |
| Anthropic partner integrations | CloudZero, Datadog, Grafana, Harness, Honeycomb, Tempo, Vantage | commercial | No | Anthropic only, per page | Auth method not stated on the Anthropic page. |

**Honest verdict.** The headline idea (menu bar, both vendors, admin keys, local) already exists and is MIT: CodexBar. A Meter built only to "show Anthropic and OpenAI spend" duplicates it. The remaining gaps, from CodexBar's own docs, are:
1. Admin keys in the Keychain instead of a config file.
2. A narrow, audit-friendly app with **no** cookie scraping and no reuse of Claude Code OAuth tokens.
3. Per-API-key and per-project breakdown with names (new Anthropic Analytics API and OpenAI `api_key_id`).
4. Local history up to the 365-day API window, and local budgets with notifications.

None of these is large. Ranked options:

| Rank | Option | Effort | Fit |
|---|---|---|---|
| 1 | **Run CodexBar with the two admin keys, today.** Judge whether the gap matters. | 30 min | Covers glance and trend. |
| 2 | **Contribute upstream** to CodexBar: Keychain storage for admin keys, per-key breakdown, budget notifications. Needs owner sign-off per VISION.md, so open an issue first. | Days, uncertain merge | Best outcome if accepted, no new app to maintain. |
| 3 | **Build Meter narrowly** as scoped in section 13: two providers only, Keychain, breakdowns, budgets, 365-day local history. | 1 to 2 weeks | Only worthwhile if 1 and 2 are rejected or the "no cookie or OAuth-reuse surface" property matters to the owner. |
| 4 | Add **ccusage** alongside for local agent logs | minutes | Complementary, not a substitute. |
| 5 | Proxy/observability stacks (Helicone, Langfuse, LiteLLM) | high | Needs a server and traffic rerouting. Contradicts "no server". |

Recommendation: do option 1, file the option 2 issue, and only start option 3 after that feedback. If Meter is built, do not market it as "the only tool".

Sources: https://github.com/steipete/CodexBar (README, `docs/openai.md`, `docs/claude.md`, `VISION.md`); https://github.com/ccusage/ccusage ; GitHub repo API.

---

## 11. Keychain storage without a paid Developer ID

Sources (Apple, fetched 2026-11-13): TN3137 "On Mac keychains" https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains ; TN3127 "Inside Code Signing: Requirements" https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements ; `kSecAttrAccessible` https://developer.apple.com/documentation/security/ksecattraccessible ; `kSecUseDataProtectionKeychain` https://developer.apple.com/documentation/security/ksecusedataprotectionkeychain ; Access Control Lists https://developer.apple.com/documentation/security/access-control-lists ; `SecAccessCreate` https://developer.apple.com/documentation/security/secaccesscreate(_:_:_:) ; `kSecAttrAccess` https://developer.apple.com/documentation/security/ksecattraccess.

| Question | Answer |
|---|---|
| Are SecItemAdd / SecItemCopyMatching usable from an ad-hoc signed app? | **Yes, against the file-based (login) keychain.** On macOS the SecItem API "defaults to targeting the file-based keychain" (TN3137). No entitlement is needed for that path. |
| Why not `kSecAttrAccessible`? | Apple: it applies on macOS only "if you also set a value of true for `kSecUseDataProtectionKeychain`... or `kSecAttrSynchronizable`". So the brief's suggestion only works with the data protection keychain. |
| Can an ad-hoc app use the data protection keychain? | **Not realistically.** TN3137: access groups come from code signing entitlements, and "These entitlements must be authorized by a provisioning profile", which needs an app-like bundle with the profile embedded. An ad-hoc signed app has no profile. (A free Apple Development team may issue a profile; not verified here.) |
| Access group / entitlement limits | File-based keychain has no access groups, it uses ACLs. `keychain-access-groups` is a data-protection feature (https://developer.apple.com/documentation/bundleresources/entitlements/keychain-access-groups). Do not set `kSecAttrAccessGroup`. |
| Access model on the file-based keychain | Per-item ACL. The creating app is trusted by default. Another app gets a prompt: Deny, Allow, or Always Allow (adds that app to the ACL). `kSecAttrAccess` is mutually exclusive with `kSecAttrAccessControl` and applies only to non-data-protection items. (Access Control Lists, `kSecAttrAccess`) |
| Does the item survive app updates when the signature changes? | **Item survives. Silent access probably does not.** TN3127: "Ad hoc signed code... has a designated requirement but it's tied to that specific version of the code." macOS cannot track identity across versions, so each rebuilt binary is a new "app" to the ACL and expect a keychain prompt after each update (Apple states the equivalent for TCC prompts; the keychain-ACL re-prompt is an inference and must be confirmed in a spike). Item is not lost, only the trust. |

**Robust approaches, ranked:**

1. **Sign every build with one stable self-signed local code-signing certificate** (created once in Keychain Access > Certificate Assistant, free). Its designated requirement is based on the certificate, not the cdhash, so the ACL entry should keep matching across updates (TN3127: DR "mostly checks who signed the code"). Not a Gatekeeper fix, distribution of a non-notarized app still needs right-click Open. **Spike required** to confirm no re-prompt across two builds.
2. **Store via the `security` CLI with the Apple-signed `/usr/bin/security` as the trusted app** (`security add-generic-password -a ... -s ... -U -T /usr/bin/security -w` as the last option so it prompts instead of putting the key in argv; `man` text: "Use of the -p or -w options is insecure. Specify -w as the last option to be prompted"). Meter reads by spawning `security find-generic-password -w`. The ACL trusts a stable Apple binary, so no prompts across Meter builds. Cost: any process of the same user can run the same command without a prompt, which is weaker than app-specific trust, and the key crosses a pipe on every read.
3. **Accept one "Always Allow" per update** (plain `SecItemAdd`, no ACL tweaks). Simple, honest, annoying.
4. Never `-A` ("Allow any application to access this item without warning (insecure, not recommended!)" per the `security` help text).
5. Plain file with 0600 (what CodexBar does): works, weakest.

Recommendation: plain SecItem on the file-based keychain, generic password, `kSecAttrService = "com.meter.admin-key.<provider>"`, `kSecAttrAccount = <provider>`, no access group, no `kSecAttrAccessible`; sign with a stable self-signed certificate (option 1). Keep option 2 as the fallback if the spike shows re-prompts.

---

## 12. Sign-in options (can users sign in instead of pasting admin keys?)

**Short answer: no vendor offers a way for a third-party app to sign a user in and read org spend.** The nearest thing is Anthropic's `org:admin` OAuth token, available only through Anthropic's first-party CLI.

### 12.1 What each vendor documents

| Question | Anthropic | OpenAI |
|---|---|---|
| (a) Official OAuth or "Sign in with" for third-party apps reading org cost | **Not documented.** `ant auth login` opens "a browser-based OAuth flow against the Claude Console" and can request `--scope "org:admin"` (granted only to admin, owner, primary owner). That token works on Admin API, usage, cost, Claude Code analytics endpoints. I found **no third-party client registration**; `ant profile set client_id` is a CLI config knob, not a registration programme. Tokens are "short-lived". Sources: https://platform.claude.com/docs/en/cli-sdks-libraries/cli/authentication (Admin access) ; https://platform.claude.com/docs/en/manage-claude/admin-api (OAuth bearer token) | **Sign in with ChatGPT** exists (https://developers.openai.com/siwc/quickstart.md) but: identity scopes `openid profile email` "don't grant access to ChatGPT conversations or OpenAI API resources". The ChatGPT-plan scopes `offline_access resource.invoke chatgpt.tokens.use.direct` let an **open-source** client run eligible Responses API requests on the user's plan. It "doesn't grant access to the user's API key or conversations". Commercial use is a limited trial. **No scope reads org costs or usage.** (https://developers.openai.com/siwc/token-sharing-open-source/sign-in.md) |
| Codex CLI / Claude Code login: what it grants | Claude Code OAuth is for ordinary Claude Code use and inference. Console sign-in in Claude Code stores an OAuth profile. https://code.claude.com/docs/en/authentication.md | Codex ChatGPT login: usage follows the ChatGPT workspace; cached in `~/.codex/auth.json` or OS keyring. https://developers.openai.com/codex/auth.md |
| Terms on reusing those tokens | https://code.claude.com/docs/en/legal-and-compliance.md: OAuth "is intended exclusively for purchasers of Claude Free, Pro, Max, Ultra, Team, and Enterprise" for ordinary use of Claude Code and native apps. "Anthropic does not permit third-party developers to offer Claude.ai login into their own applications, or to route requests through Free, Pro, Max, or Ultra plan credentials on behalf of their users. Moreover, developers may not collect, store, or intermediate Claude.ai credentials or session tokens." | OpenAI terms unverified (403). The SIWC docs are the sanctioned route and cover inference only. |
| (b) Mint an admin key after login | **No.** "You create API keys in the Claude Console. The Admin API can only read, rename, and change the status of existing keys." No device-code flow documented for keys. (admin-api FAQ) | **No bootstrap.** `POST /organization/admin_api_keys` needs an existing admin key (spec L11120). Codex device-code login (`codex login --device-auth`) is for Codex, not the Platform. |
| (c) Read-only or narrower credentials | None (section 1). Only `org:admin` OAuth vs admin key vs personal key, all full admin. | None documented for costs. RBAC "Usage: Read" exists as a custom-role permission for the dashboard; no documented link to an admin key. Spike candidate. |
| (e) Subscription usage (Pro/Max, Plus/Pro) | See 12.3 | See 12.3 |

### 12.2 Unofficial approaches: recommend against

| Approach | Verdict |
|---|---|
| Scraping console session cookies or private dashboard endpoints (`console.anthropic.com`, `platform.openai.com`) | **Do not.** Anthropic consumer terms (effective 2025-10-08, https://www.anthropic.com/legal/consumer-terms) forbid "to access the Services through automated or non-human means, whether through a bot, script, or otherwise" except via an API key or where explicitly permitted, and forbid to "crawl, scrape, or otherwise harvest data". OpenAI terms could not be fetched (403), unverified. Technically fragile in any case (private routes, cookies, bot checks). CodexBar does this for some providers; Meter should not. |
| Reading Claude Code's Keychain OAuth token to call Anthropic's private usage endpoints | **Do not.** Collides with the "may not collect, store, or intermediate Claude.ai credentials or session tokens" clause above. Private endpoint, breaks without notice. |
| Reading `~/.codex/auth.json` tokens | **Do not.** Same reasoning, and the Codex docs say to treat it "like a password". |
| Legacy OpenAI `dashboard/billing/credit_grants` | Undocumented per CodexBar's own note. Skip. |

### 12.3 Subscription usage (not API spend), official routes only

| Product | Official, local, no scraping |
|---|---|
| Claude Pro/Max/Ultra | No usage API. Official surfaces: `/usage` in Claude Code, claude.ai Settings > Usage, and the **status line JSON**: Claude Code pipes `rate_limits.five_hour.used_percentage`, `rate_limits.seven_day.used_percentage` and `resets_at` (Unix seconds) to a configured status line script, only for Pro/Max/Ultra, only after the first API response in a session. A tiny Meter helper script configured as `statusLine` could write that JSON to a file Meter watches. (https://code.claude.com/docs/en/statusline.md ; https://code.claude.com/docs/en/costs.md). Cost estimates from local logs: ccusage. |
| ChatGPT Plus/Pro (Codex) | Codex app-server JSON-RPC `account/rateLimits/read` and `account/rateLimits/updated` return `usedPercent`, `windowDurationMins`, `resetsAt` per bucket; `/status` in the CLI; dashboard at `chatgpt.com/codex/settings/usage`. Meter could spawn `codex app-server` under the user's own login. (https://developers.openai.com/codex/app-server.md ; https://developers.openai.com/codex/pricing.md). The format may change, treat as best effort. |
| Subscription dollar spend | Not available. Extra usage credits balance is shown at claude.ai Settings > Usage only. |

### 12.4 What comparable tools do

| Tool | Auth approach |
|---|---|
| CodexBar | Admin key pasted (config file), plus reuse of CLI/OAuth/cookies for subscription data |
| Anthropic partners (Datadog, Vantage, etc.) | Page does not say. Admin API docs state integrations should use an Admin key. |
| Vendor SDK/CLI | Anthropic `ant auth login --scope org:admin`; OpenAI admin key only |

### 12.5 Ranked sign-in options

| Rank | Option | Legitimacy | Can read | Effort and UX | Verdict |
|---|---|---|---|---|---|
| 1 | **Paste admin key, store in Keychain** (both vendors) | Fully documented | Everything in sections 2 to 7 | One paste per vendor. Anthropic admin key shown once at creation; set an expiry. | **Default for v1.** |
| 2 | **Anthropic: "Connect via `ant` CLI"** (`ant auth login --profile meter --scope org:admin`, Meter reads `ant auth print-credentials --profile meter --access-token`, sends `authorization: Bearer`) | Uses Anthropic's own documented tool and scope for "local development and scripting on your own machine". Meter never handles the login or refresh, `ant` does. | Same as admin key, but full-org admin and short-lived. | Needs `ant` installed. Real browser sign-in, no long-lived key stored. Token refresh by rerunning the export command (docs). Spike needed on refresh behaviour. | **Optional v1.1.** Best "sign in" experience that is actually legitimate. |
| 3 | Anthropic personal key not scoped to a workspace | Documented credential for Admin API | Same as the admin role of its owner | Extra step vs admin key, no narrower | Skip. |
| 4 | OpenAI Sign in with ChatGPT | Official, but inference-only | Nothing about spend | n/a | Not applicable to Meter. |
| 5 | OpenAI narrower key via RBAC "Usage Read" | Documented permission, link to admin keys undocumented | Possibly costs only | Unknown | Spike with a real org, could give a read-only story. |
| 6 | Subscription limits via statusline helper and `codex app-server` | Official surfaces, local | Limits percent and reset times, not dollars | Setup per tool | Optional v1.1 module. |
| 7 | Cookie scraping, token reuse of Claude Code or Codex logins | Violates or risks vendor terms | Whatever the private API returns | Looks easy, breaks often | **Recommend against.** |

---

## 13. Local storage

Data model: one row per (provider, day, dimension set) with cost in integer micro-dollars and optional tokens. Store daily aggregates only. Do not store raw API responses.

| Scenario | Rows | Size (SQLite, 2 indexes, about 200 B per row) |
|---|---|---|
| Typical: 2 providers x 365 days x about 20 groups (model x key or project) | about 14,600 | about 3 MB |
| Heavy: 2 x 365 x 150 groups | about 110,000 | about 22 MB |
| Worst plausible: 2 x 365 x 1,000 groups | about 730,000 | about 150 MB, prune or roll up old days to model level |

Anthropic Analytics API only looks back 365 days from now and not before 2026-01-01, so a local copy is the only way to keep longer history, a real Meter advantage. SQLite (`/Library` of the app container, `~/Library/Application Support/Meter/meter.sqlite`) beats JSON once breakdowns exist. These sizes are estimates, not measured.

---

## 14. Proposed v1 scope

### Screens
1. **Menu bar glance** (popover): today, month to date, last 7 or 30 day sparkline, per vendor and combined. Shows "data as of <time>" using Anthropic `data_refreshed_at` and the poll time. Badge when a budget is near.
2. **Window, breakdowns:** (a) by model, (b) by API key (name from list endpoints), (c) by workspace or project, (d) per day table. Provider tabs. Claude Code per-user table (Anthropic actor cost, plus `usage_report/claude_code` lines of code, commits) behind an "advanced" tab.
3. **Settings:** paste keys (Keychain), poll interval, budgets, test connection, delete key. Plain-language link to each console page to create or revoke.
4. **Local notifications:** budget thresholds (50, 80, 100 percent of a monthly or daily user-set limit), key expiring within 7 days, auth failure (401/403), a day-over-day spike.

### Possible versus not

| Possible | Not possible with the APIs |
|---|---|
| Daily cost, per model, per key, per project or workspace, both vendors | Real-time cost (Anthropic Analytics lags 4 to 24 h; legacy 5 min; OpenAI undocumented) |
| Month-to-date vs user-set local budget | Reading Anthropic Console workspace spend limits or credit balance (console-only, nothing documented) |
| Read OpenAI org and project hard spend limits and alerts | OpenAI credit balance (no endpoint) |
| Token and cache stats by model and key | Subscription dollars; Pro/Max/Plus limits only through the status line helper or `codex app-server`, not via an API key |
| Claude Code analytics per user (Console org) | Individual Console accounts and claude.ai Team plans (no Admin API) |
| History beyond vendor windows (local copy) | Matching the invoice exactly (credits not in Anthropic cost data, OpenAI undocumented) |
| | Gemini (no admin cost API found) |

### Poll cadence
Anthropic: legacy `cost_report` every 5 to 15 min for today's glance, new Analytics hourly for key and model breakdown plus a nightly revision pass over the last 7 days (and the previous month for its first 7 days). OpenAI: every 15 min with backoff on 429 and `Retry-After`. Names: daily. Spend limits: hourly. Pause polling when the Mac sleeps, refresh on wake and on popover open if older than 5 min.

### Risks
1. **Product overlap** with CodexBar (section 10). Highest risk.
2. **Beta API risk:** Anthropic analytics is beta (header `analytics-usage-cost-2026-08-24`), legacy marked legacy. Build a source adapter so either can be swapped, and fall back to legacy when beta fails.
3. **Keychain re-prompts on ad-hoc builds** (section 11), unproven. Spike two builds with a stable self-signed cert before committing to UX copy.
4. **Admin key blast radius:** Anthropic admin keys have no read-only scope. A leaked key can manage members, invites, workspaces and keys. Mitigate: set an expiry, recommend a dedicated key just for Meter, never log it, Keychain only, optional `ant` OAuth route.
5. **Unverified OpenAI facts:** history depth, freshness, rate limits, whether "Usage Read" can scope a key, terms of use (403). Close with a real-key test by the owner, not by this research.
6. **Org eligibility:** many users (individual Console accounts, claude.ai Team, ChatGPT-only) cannot create admin keys, so Meter will be unusable for them. Say so in onboarding.
7. **Distribution:** ad-hoc or self-signed app is not notarized, so Gatekeeper warnings on downloaded builds (not verified in this research). Ship as build-from-source plus a documented right-click Open.
8. **Number drift:** Anthropic cost excludes credits and priority commitments, OpenAI sign conventions unknown. Label the numbers "API list cost as reported", not "your bill".

### Suggested first spike list (needs the owner's real keys, not done here)
- Call each cost endpoint once, record real history depth and delay.
- Test a billing-role or custom-role OpenAI "Usage Read" key and an Anthropic billing-role personal key against the cost endpoints.
- Two ad-hoc builds and two self-signed builds against a Keychain item, record prompts.
- `ant auth login --scope org:admin` refresh behaviour over 24 h.
