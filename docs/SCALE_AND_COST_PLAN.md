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

- **Leaderboard is precomputed and refreshed incrementally**
  (`LeaderboardStanding` + `RefreshLeaderboardStandingsJob`): completions
  coalesce into one refresh per 3 s window, and that refresh upserts only the
  identities whose responses changed since the snapshot's own high-water
  mark (rank is derived at read time from the indexed `total`, never
  stored). The first version rewrote the whole board per window — the load
  test measured that at 50k identities as an OOM on a 512 MB instance and
  ~30k row writes/s on Postgres for the event. The per-finisher read is
  indexed and measured **flat (~28 ms) from 300 to 10,000 identities**.
  "You" is always live from your own rows.
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
| 4 | 2 | 90% failed | Same collapse at ~14 req/s total; `show` median 6.4 s. Render Events for the window: **"Ran out of memory (used over 512MB)"** + crash loop on a 0.5c-512mb Starter; CPU never above 60%. Cause: `LeaderboardStanding.refresh!` rewrote the whole 50k-row board every 3 s window inside the web process. Fixed: incremental upserts, read-time rank, `rank` column dropped. |
| 5 | 2 | 0.10% failed, **~12 s median on every endpoint** | On the resized 1c-2g (prod's 2 GB shape) with the incremental refresh: no OOM, board serving. Uniform latency across endpoints of very different cost = queueing: the full rebuild of the 50k seeded board ran in one transaction, so every 3-second job saw "no snapshot" and started another — overlapping rebuilds holding the GVL. Fixed: `surveys.leaderboard_refreshed_at` watermark + per-batch commits, single-flight cache claim (`:busy` → job retries), first-read bootstrap inline only ≤ 2,000 identities, else via the job. |
| 6 | 2 | 0 failed, medians 2–5 s | Single-flight refresh live. The one-off 50k background build shared the box with requests; busy-retry chains could stack (fixed: retries coalesce behind the debounce claim). |
| 7 | 2 | 0 failed, **~1 s median on every endpoint** (min 120–155 ms) | Board built, nothing else running. Web CPU only **25–30%**, memory 20% (Render Metrics) — yet uniform queueing. **Database** Metrics: **CPU pinned at 100% of its 0.1-CPU limit**, memory 60–80% of 256 MB, disk **1,500–2,000 write ops/s**; the same Postgres tier production runs (and it had **OOM-crashed** during run 4). 55 app queries per journey (+~10 cache/rate-limit in prod); the leaderboard read was 23 → batched alias lookup → 12. |
| 8 | 1 | 0 failed, median **228 ms** (show 481, submit 293, progress 233, leaderboard 266), p95 839 ms | Half the load, a quarter of the latency: the classic knee of a saturated resource — the DB was still touching 100% CPU at ~6 req/s. Healthy service time ≈ 70 ms server-side for the API endpoints, ≈ 320 ms for the 150 KB page. |

Standing conclusions: (1) **five** production fixes came out of the harness
— named rate limits, the scale knob, the whole-board refresh, the rebuild
storm, the per-name leaderboard lookups; (2) the play page weighs ~150 KB, so
the CDN/page-trim stage is load-bearing at 83 arrivals/s (~7 GB of HTML per
event); (3) **the database is the first wall, not the web tier.** A
Basic-256mb Postgres (0.1 CPU, 256 MB — production's tier) saturates at
~1–2 arrivals/s with the web instance three-quarters idle, and it OOM-crashed
under a 2/s burst. Every respondent request writes to it several times
(Solid Cache entries, rate-limit counters, Solid Queue rows, the response
itself). Ordering consequence for the plan: **DB tier + Stage 5 (cache and
rate-limit counters onto Key Value/Valkey) come BEFORE any web scale-out** —
more web instances against this database would change nothing. Measured
healthy service times: ~70 ms server-side for consent/progress/submit/
leaderboard, ~320 ms for the page (≈ 160 ms of every k6 number is US→Frankfurt
network). Next: scratch DB on a real tier + Key Value for cache/rate limits,
then 2/s → 10/s again, then the Pro Plus web ceiling.

## 3. What remains, in order (needs dashboards/accounts)

- **Stage 5 code is on the branch**: `config.cache_store` switches to Render
  Key Value (Valkey) whenever `REDIS_URL` is set, and `rate_limit` counters
  follow it (they resolve their store from `cache_store`). Solid Cable and
  Solid Queue stay on Postgres. Needs: a Key Value instance in Frankfurt
  (free 25 MB is ample for counters + the small aggregate cache) and
  `REDIS_URL` on the web service — scratch first, production after the
  scratch rerun shows the DB CPU dropping off the graph. Counters reset to
  zero at the flip; do it on a quiet day.

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
