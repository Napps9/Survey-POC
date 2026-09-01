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

## 3. What remains, in order (needs dashboards/accounts)

1. **Done 2026-09-01**: the four `generateValue` secrets (`SECRET_KEY_BASE`
   + the three `ACTIVE_RECORD_ENCRYPTION_*` values) are backed up outside
   Render (see `docs/ENCRYPTION_KEYS.md`). Still owed: confirm Postgres
   backup retention off the dashboard, record `SHOW max_connections;`, and
   test a restore.
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
   otherwise, and Basic-256mb's `max_connections` is far below the planning
   figures until the event-day resize); PgBouncer with **direct** URLs for
   migrations, Blazer and the worker (advisory locks and session `SET`s are
   unsafe through transaction pooling). Re-tune the 512 MB memory regime for
   the new instance size.
7. **Proof run at 1.5× peak** (125 arrivals/s, 50k-row table) — gate: zero
   5xx, p95 < 1 s on submit, flat leaderboard/results latency, bounded
   brownout echo, no health flaps, no autovacuum cliff.

## 4. Event day

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

## 5. Cost (list prices, Aug 2026 — confirm the two soft lines on dashboards)

| | $/month |
|---|---|
| Steady state (Pro workspace, 2×Standard + worker, Basic-4gb PG, Key Value, CDN/R2 free tiers) | **~185** |
| Per event (8×Pro Plus ~4 h + Postgres resized for the day, second-prorated) | **+~25–30** |
| Anthropic, respondent path (plain Verto) | 0 |

Soft lines to confirm before quoting a client: the mid-tier Postgres price
(~$500/mo interpolated for the event-day tier) and the actual
`max_connections` of the chosen tier (`SHOW max_connections;`).

**The infrastructure delta for 50,000 people is ~$30. The cost is the
engineering — most of which is now on this branch.**
