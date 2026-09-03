# Load-test harness

Proves (or refutes) the platform's capacity for a burst of respondents —
the acceptance gate for the high-volume infrastructure work is a clean run of
this harness at **1.5× the expected peak** against a production-shaped stack.

## Hard rule

**Never point this at production.** A load test is a denial-of-service by
design; against the live service it would take down whatever events are
running. `journey.js` refuses hostnames that look like production, but the
real protection is the procedure: it runs only against a **throwaway Render
service + database** (or a local Docker stack) created for the purpose and
deleted afterwards.

## Setup

1. Create a scratch Render web service + Postgres from this repo's
   `render.yaml` (any branch), or run the app locally against Postgres.
   Configure it like production for the scenario under test (instance plan,
   `WEB_CONCURRENCY`, `RAILS_MAX_THREADS`, PgBouncer on/off) — **plus
   `PLAYER_RATE_LIMIT_SCALE=1000`**, which production does not set. The
   player endpoints rate-limit per IP (consent's 30/min is the tightest) and
   k6 drives the whole burst from a handful of runner IPs, so without the
   scale-up ~99% of requests 429 inside the first minute (observed
   2026-09-01: 36 successful page loads, then a wall of 429s).
2. Seed it — **the O(N) endpoints are invisible on an empty table**, so the
   responses table must be at full target size before any number means
   anything:

   ```
   LOAD_TEST_SEED=1 RESPONSES=50000 bin/rails load_test:seed
   ```

   Additive-only (never deletes or updates anything); re-running appends.
   It prints the play path — the `TOKEN` below is the last segment.
   Do **not** use `DemoSeeder` for this: it destroys its fixed slugs on boot.

3. Install k6 (https://k6.io) on the machine driving the test — ideally not
   the machine serving it.

## Running

Smoke (default: 10 arrivals/s, compressed dwell):

```
k6 run -e BASE_URL=https://<scratch-host> -e TOKEN=<publish_token> test/load/journey.js
```

Event shape (50k over ~10 min ≈ 83 arrivals/s), then the 1.5× proof run:

```
k6 run -e BASE_URL=... -e TOKEN=... -e ARRIVALS_PER_S=83  -e RAMP_S=120 -e HOLD_S=480 test/load/journey.js
k6 run -e BASE_URL=... -e TOKEN=... -e ARRIVALS_PER_S=125 -e RAMP_S=120 -e HOLD_S=480 test/load/journey.js
```

Brownout echo (adds a scenario replaying submits in the triple-fire shape the
service worker's offline queue produces):

```
k6 run ... -e BROWNOUT=1 test/load/journey.js
```

`DWELL_SCALE=0.05` (default) compresses think-time so a journey takes ~15 s:
same request *rate* shape, far fewer VUs. For the final rehearsal use
`DWELL_SCALE=1` (real ~4–5 min dwell; needs ~25–30k VUs at 83/s — a large
runner or k6 distributed mode) so connection-concurrency effects are real.

### From GitHub Actions (no local machine needed)

`.github/workflows/load_test.yml` runs the same script from a GitHub-hosted
runner: Actions tab → "Load test (scratch only)" → Run workflow, or dispatch
it via the API. Inputs mirror the env knobs above; the guard step refuses
production-looking hostnames before k6 even starts. The full text output and
`k6-summary.json` are uploaded as a run artifact (one per generator).

`GENERATORS=N` (dispatch input `generators`, 1–8) splits the arrival rate
across N runners — integer shares that sum to the total, all running the same
ramp — because one standard runner is a single source IP with two shared
vCPUs, and runs 12 and 13 met the same ~160–180 req/s ceiling against two
very different web boxes. Keep each generator at or below ~20 arrivals/s
(the rate one runner has proven clean): 40/s → 2, 83/s → 4–5, 125/s → 7.
Add the per-generator `http_reqs` and `iterations` for the run's totals. The
summary is printed in full, so each generator also shows where its time
went: a queue that is `http_req_waiting` is the server's, one that is
`http_req_blocked` is the runner's own. The `DWELL_SCALE=1` rehearsal still
needs bigger machines than the standard runner.

`SCRIPT=test/load/ping.js` (dispatch input `script`) swaps the journeys for
the path-only probe: one cheap endpoint (`PING_PATH`, default `/up` — no
database, cache or rate limit) at `ARRIVALS_PER_S` **requests** per second.
Run it when the journeys hit a ceiling that does not move with the web box:
if `/up` queues at the same rate the ceiling is the path (edge, proxy,
accept queue); if it runs clean far above, the ceiling is in what the
journeys touch (database, Key Value, the app).

`SKIP=leaderboard` (dispatch input `skip`; also `manifest`, `service_worker`,
comma-separated) drops optional steps from the journey, so the same arrival
rate can be re-run without the board read to see how much of a ceiling the
board's two counts over a big snapshot account for. The writes are never
skippable.

## What to record per run

- k6 summary: per-endpoint p50/p95/p99, `http_req_failed`, `journey_duration`.
- Server side: Postgres CPU, connections (`pg_stat_activity` count), writes/s,
  slowest queries; instance CPU/RSS; any memory-watchdog or health-check
  events in the logs; autovacuum activity on `responses` across the window.
- The derived number that sizes the fleet: **mean service time** on
  `progress`/`submit` — instance count = peak req/s × service time ÷
  (slots × 0.65). See `docs/` scale plan.

## Pass criteria (1.5× proof run)

- Zero 5xx; p95 < 1 s on `submit`/`progress`; leaderboard p95 < 1 s with the
  table at full size (flat as it grows — that's the O(N)-work-is-gone check);
  bounded retry echo under `BROWNOUT=1`; no health-check flaps; no autovacuum
  cliff.
