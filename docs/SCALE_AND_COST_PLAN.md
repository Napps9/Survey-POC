# High-volume events — capacity, cost and runbook

_Target: **50,000 respondents arriving in ~10 minutes** on one plain
(non-quiz) Verto with the token leaderboard on, under EU/UK data residency,
scaling back down between events. Written 2026-09-01 alongside the
`claude/vertono-survey-scale-infra-*` branch; the load-test numbers in §2 are
**estimates until `test/load/` has run against a production-shaped scratch
stack** — treat the k6 proof run as the acceptance gate, not this document._

## 1. What the burst looks like

A plain Verto respondent costs **7 dynamic requests** (HTML, manifest,
service-worker, consent, one `/progress` — it fires once per session, not per
card — `/submit`, and the auto-fetched leaderboard). 50,000 arrivals over 10
minutes ≈ 83/s:

| | Value |
|---|---|
| Average dynamic rate over the ~15-min window | ~390 req/s |
| Structural peak (arrivals × 7) | ~580 req/s |
| Planning peak (burst margin + retry echo) | **600–700 req/s** |
| Peak DB write statements | ~800/s |
| Concurrently mid-survey | ~17–25k people |
| Added storage | ~150 MB (one row per response) |

Web-tier sizing is a formula, not a guess — measure mean service time with the
harness, then:

```
instances = peak_req_per_s × mean_service_time_s ÷ (WEB_CONCURRENCY × RAILS_MAX_THREADS × 0.65)
```

At an assumed 100 ms on Pro Plus (4×5 = 20 slots, 65% target utilisation):
**6 instances, pinned to 8 for the event window.** If the deck later gains
graded quiz cards, requests triple (~21–22/respondent) — resize to ~15–17.

## 2. What has already shipped (code, this branch)

- **Leaderboard is precomputed** (`LeaderboardStanding` +
  `RefreshLeaderboardStandingsJob`): completions coalesce into one standings
  scan per 3 s window; the per-finisher read is indexed and measured **flat
  (~28 ms) from 300 to 10,000 identities**. "You" is always live from your own
  rows.
- **Anonymous names derive from the digest** (`PlayerAlias`): no probe loop;
  the unique index is the only collision check.
- **`/results`, `/regions`, `/scores` are cached per 10 s window**
  (stampede-safe, deck-edit busts the key); `/regions` no longer materialises
  every tagged row (grouped COUNT + per-country batched passes).
- **The live tally broadcasts from a coalesced job**, off the respondent's
  thread.
- **`/up` treats pool exhaustion as busy, not dead** — no more health-check
  restarts of saturated-but-healthy instances. Hard DB failure still fails it.
- **The offline submit queue backs off** (exponential + jitter, Retry-After
  honoured, drain rate-limited; `CACHE_VERSION` → v41), and a queued consent
  decline can no longer be silently dropped on a transient fault.
- **30 s `statement_timeout`** (migrations run at 600 s via
  `preDeployCommand`); redundant `responses[survey_id]` index dropped;
  `AI_GRADE_SLOTS=0` now genuinely disables respondent-path Claude calls;
  `REQUEST_WAIT_TIMEOUT` opts in request shedding where the proxy stamps
  `X-Request-Start`.
- **`test/load/`**: k6 journey (ramp, brownout echo scenario, refuses
  production hostnames) + `LOAD_TEST_SEED=1 RESPONSES=50000 bin/rails
  load_test:seed` (additive-only seeding; card indexes are the contract with
  `journey.js`).

Deliberately deferred until the load test says they matter: caching the
token→survey resolution and the parsed deck (both are indexed/sub-ms today).

### 2b. Load-test log (scratch env, 2026-09-01 → 02)

Setup: scratch web service `vertonow.onrender.com` (hand-made, builds this
branch, single instance, `WEB_CONCURRENCY` unset) + scratch Basic-256mb
Postgres (`max_connections` 103), 50,000 seeded responses. k6 runs from
GitHub Actions (`.github/workflows/load_test.yml`, fired by pushing
`test/load/RUN`) — one US runner IP, ~160 ms network floor to Frankfurt.
`.onrender.com` is fronted by Cloudflare, so an origin that stops answering
surfaces as **Cloudflare 502s**, not app errors.

| Run | Arrivals/s | Outcome | What it taught |
|---|---|---|---|
| 1 | 10 | 99% failed | Per-IP rate limits walled off the single runner IP — **and** exposed that every unnamed `rate_limit` in a controller shares one counter (successes decayed in journey order: consent 32, submit 18, leaderboard 0). Fixed: `name:` on every limit (PlayerController, SharedResultsController); `PLAYER_RATE_LIMIT_SCALE` knob. |
| 2 | 10 | 99% failed, same shape | Deploy race: the run started before the knob build was live. |
| 3 | 10 | 97% failed | **0 × 429** — knob verified. 9,284 × 5xx (Cloudflare 502, origin not answering) + 1,404 × 60 s timeouts. Healthy requests: median 367 ms end-to-end (~200 ms after the network floor). |
| 4 | 2 | 90% failed | Same collapse at ~14 req/s total; `show` median 6.4 s. **An instance that cannot serve 14 req/s is not a capacity data point** — it is undersized (Free tier, 0.1 CPU) or restart-looping. Instance plan unconfirmed at time of writing; the Render Events/Metrics tabs for 09:06–09:12 UTC settle it. |

Standing conclusions so far: (1) two production bugs fixed for free;
(2) the play page weighs ~150 KB, so the CDN/page-trim stage is load-bearing
at 83 arrivals/s (~7 GB of HTML per event); (3) every service-time number
above is **provisional** until the scratch instance is production-shaped —
next run goes on a Standard (prod's 2 GB shape) for the baseline, then one
Pro Plus with `WEB_CONCURRENCY=4`/`RAILS_MAX_THREADS=5` ramped to failure
for the per-instance ceiling that sizes the fleet.

## 3. What remains, in order (needs dashboards/accounts)

1. **Done 2026-09-01**: the four `generateValue` secrets (`SECRET_KEY_BASE`
   + the three `ACTIVE_RECORD_ENCRYPTION_*` values) are backed up outside
   Render (see `docs/ENCRYPTION_KEYS.md`). **Backups (confirmed 2026-09-01):**
   Point-in-Time Recovery to any timestamp in the past **3 days** (7 days once
   the workspace is Pro — the same upgrade autoscaling needs), plus manual
   Exports retained >=7 days. Routine: create an export now (it becomes the
   restore-test artifact — restore it into the scratch DB when that exists),
   another the day before any event or migration-heavy deploy, and longer-term
   a scheduled export to our own bucket so a copy lives outside Render (P1-2).
   **`max_connections` = 103** — measured 2026-09-01 on the scratch DB at the
   same tier (Basic-256mb) production runs. With ~3 slots reserved for
   superuser, the usable budget is ~100: today's single-instance shape (pool
   threads+12 = 15) is comfortable, but the scale-out shape is not — 6
   instances at `WEB_CONCURRENCY=4` need ~170 even after the pool-formula fix,
   so PgBouncer and/or the event-day tier resize is a hard prerequisite, not
   headroom. Also observed on the
   live instance: the built-in Connection Pool (PgBouncer) toggle exists and
   is off (flip it only in the scale-out stage, after the pool-formula
   change), and inbound Postgres access is open to 0.0.0.0/0 — deliberate
   for workstation imports, but tighten to specific IPs when the workflow
   allows.
2. **Scratch environment + baseline load test** (`test/load/README.md`).
   Never against production — the harness is a denial-of-service by design.
3. **Active Storage → Cloudflare R2** (EU jurisdiction;
   `request_checksum_calculation: "when_required"` — R2 rejects CRC32),
   migrate blobs **and their `service_name`**, then remove the disk from
   `render.yaml`. This is what unpins the service from one instance.
4. **Cloudflare CDN** — prerequisites, not tuning: **trusted proxies /
   `CF-Connecting-IP` before orange-clouding** (every `rate_limit` keys on
   `remote_ip`; 50k respondents via a few dozen edge IPs mass-429s the event
   otherwise); SSL **Full (strict)** (`force_ssl` + Flexible = redirect loop);
   CSP + `CACHE_VERSION` bump shipped **weeks ahead** (installed workers keep
   the old CSP until the script bytes change); bypass or job-ify the 240 s
   slow-tier endpoints (Cloudflare cuts at ~100 s). Then
   `public_file_server.headers`, `asset_host`, Thruster.
5. **Rails.cache + Action Cable → Render Key Value (Valkey)** (add the redis
   gem; switch on a quiet day — rate-limit counters reset at the flip).
6. **Scale-out** — no region migration: the live web service AND database
   are already in Frankfurt (owner-confirmed 2026-09-01; `render.yaml` was
   stale and has been corrected on this branch, the DB is `Basic-256mb`,
   PostgreSQL 18). Remaining order: Solid Queue out of Puma (a
   `config/puma.rb` change — it is hard-enabled in production) **before**
   `WEB_CONCURRENCY=4`; drop the `+12` from the pool (see the note in
   `config/database.yml` — the app exhausts connections at three instances
   otherwise, and Basic-256mb's measured `max_connections` of 103 is far
   below the planning
   figures until the event-day resize); PgBouncer with **direct** URLs for
   migrations, Blazer and the worker (advisory locks and session `SET`s are
   unsafe through transaction pooling). Re-tune the 512 MB memory regime for
   the new instance size.
7. **Proof run at 1.5× peak** (125 arrivals/s, 50k-row table) — gate: zero
   5xx, p95 < 1 s on submit, flat leaderboard/results latency, bounded
   brownout echo, no health flaps, no autovacuum cliff.

## 4. Event day

- **Database storage: DONE 2026-09-01 — raised 1 GB → 10 GB** (was 67% full).
  Two Render rules to plan around: storage changes are limited to **once per
  12 hours** (so there is NO emergency mid-event bump — size days ahead), and
  autoscaling, if enabled, fires at 90% full, +50% rounded to 5 GB, also max
  once per 12 h. **Autoscaling enabled 2026-09-01**; the fixed raise stays the
  primary control. Real tier prices off the dashboard: 0.1c-256mb $6, 0.5c-1g $19,
  1c-2g $40/mo (24 tiers total; the event tier gets read off the same list).
- **Freeze deploys**: a green push to `Main` auto-deploys via CI's hook — mid
  event that is a migration plus a rolling restart. Disable the hook (or gate
  the CI job) for the window.
- **Pre-scale, don't autoscale**: pin instances to the event count hours
  ahead and verify all are up and passing health checks; reactive scaling
  arrives after a 10-minute burst is over. Resize Postgres the day before.
- Set `MEMORY_WATCHDOG_RESTART_PERCENT=0` (log-only) for the window —
  synchronised 90% restarts are a capacity dip at peak.
- Do not bump `CACHE_VERSION` during the window (it reloads every idle
  in-flight respondent).
- Degrade switches, in order: disable the live broadcast; `AI_GRADE_SLOTS=0`
  (already honoured); leaderboard is precomputed so it stays on.
- Decide location search in advance: paid LocationIQ (`GEOCODE_MAX_RPS` up)
  or drop the card — at 2 req/s app-wide it silently returns nothing at 50k.
- Afterwards: scale back down (2 × Standard web, baseline Postgres tier).

## 5. Cost (dashboard-confirmed prices, 2026-09-01)

Real Postgres compute tiers (read off the live instance's Plan page —
24 tiers, $0 free → $11,000/mo at 128c-1TB). The ones that matter here:

| Tier | Price | Role |
|---|---|---|
| 0.1c-256mb | $6/mo | today's tier |
| 0.5c-1g | $19/mo | steady-state candidate once real volume exists |
| 1c-4g | $55/mo | steady-state with headroom |
| **4c-16g** | **$200/mo** | **event-day tier (recommended)** — 4 vCPU for ~800 writes/s, 16 GB puts it in the top connection band |
| 8c-32g | $400/mo | conservative alternative if the 1.5× proof run says so |

| | $/month |
|---|---|
| Steady state (Pro workspace $25, 2×Standard web + worker $57, Postgres 0.5c-1g→1c-4g $19–55, 10 GB storage $3, Key Value ~$10, CDN/R2 ~$0) | **~$115–150** |
| Per event (8×Pro Plus ~4 h ≈ $8 + Postgres at 4c-16g for the day ≈ $7, second-prorated) | **+~$15–20** |
| Anthropic, respondent path (plain Verto) | 0 |

The tier change restarts the database — it happens the day before, in the
runbook, never mid-event. `max_connections` at the current tier is **103**
(measured on the scratch DB, 2026-09-01); read it again after the event-day
resize, since the whole scale-out connection budget hangs off it.

**The infrastructure delta for 50,000 people is under twenty dollars. The
cost is the engineering — most of which is now on this branch.**
