# Event cutover plan — Wednesday 2026-09-09

Takes production from its current shape to the configuration **measured** to
carry the event: 50,000 respondents arriving in ~10 minutes (~83 arrivals/s) on
one plain Verto with the token leaderboard, fully branded (organisation logo +
card images), EU/UK residency.

## The decision, and what it rests on

**One 12c-24g web instance, with Active Storage on the R2 bucket.** Owner's
call, 2026-09-08, on the evidence of run 28.

| Configuration | Proven at | Result |
|---|---|---|
| **1 × 12c-24g + bucket** ← chosen | **83/s, the event rate** | 214 ms median, 402 ms p95, **0 errors in 83,776**, journeys at pure think-time, zero dropped |
| 2 × 12c-24g + bucket | 125/s, 1.5× the event | 165 ms median, 311 ms p95, 1 5xx in 71,806 |

Full run log: `docs/SCALE_AND_COST_PLAN.md` §2b, runs 26–28.

### Why the bucket is NOT optional here

A single instance has no split-brain, so it is tempting to conclude the object
storage migration can be skipped. It cannot, for a different reason: **run 28's
numbers were measured with assets on the bucket.** Of the ~980 req/s at the
event rate, Rails served ~490 and R2 served the other ~490 directly to
browsers. On the local disk Rails serves *all* of it — roughly double the
request load, and it streams the image bytes itself rather than answering a
redirect. That configuration has never been measured, and the day before a
50,000-person event is the wrong time to find out.

So **phases 0–2 of `docs/OBJECT_STORAGE_CUTOVER.md` are load-bearing** and are
in this plan. **Phase 3 (removing the disk) is not** — it exists only to unpin
the service for multiple instances, it is the one irreversible step, and it is
deliberately deferred until after the event.

### What is off the critical path

- **Phase 3, the disk removal.** Irreversible, unnecessary for one instance.
- **The Solid Queue worker service** and `RUN_SOLID_QUEUE_IN_PUMA=0`. One box
  runs the queue once in its Puma master, exactly as production does today.
  The `render.yaml` definition stays inert.
- **A second instance.** Proven by run 27 and available as a one-click option
  after phase 3, but not needed.

## Before anything else: the branch is behind Main

`origin/Main` has moved (moderation / held-text, rich text, save-warning work
from other sessions — ~2,700 lines this branch does not have). The scale branch
must be rebased onto it before merging, and per the standing rule the **full
system suite runs after the rebase**, not just the unit suite. Budget for it:
~2,670 unit tests plus ~385 system tests is the long pole of the morning.

## Timeline

Times are indicative; the ordering is what matters. Nothing here touches
production until step 3, and each step states its own rollback.

### 1. Rebase and verify (me) — ~45 min

```
git fetch origin Main
git rebase origin/Main          # resolve conflicts; expect none in our files
bin/rails tailwindcss:build     # system tests render the COMPILED stylesheet
bin/rails test                  # ~2,670
bin/rails test:system           # ~385, on its own
bin/rubocop
bin/brakeman --no-pager
bin/importmap audit
```

All five green or the merge does not happen. **Rollback:** nothing has left the
branch.

### 2. Merge to Main and let it deploy (me) — ~20 min

Push to `Main`; CI's four checks gate Render's deploy hook. Then `bin/trello_log`
the shipped work.

Production behaviour after this deploy is **unchanged**: every new piece is
inert until its env var is set. `ACTIVE_STORAGE_SERVICE` unset keeps the local
disk; `PlayerAssetUrls` returns same-origin paths; the process-local page cache
is the only live change and is transparent. **Rollback:** revert the merge, or
roll back the Render deploy.

### 3. Object storage, phases 0–2 (you + me) — ~40 min

Exactly the sequence rehearsed on scratch today, which came back 5/5 on the
smoke test. Full detail in `docs/OBJECT_STORAGE_CUTOVER.md`.

- **Phase 0 (you):** create the EU bucket + a bucket-scoped read/write token,
  set the five `STORAGE_*` vars on the production web service, leave
  `ACTIVE_STORAGE_SERVICE` unset. *Rollback: unset the vars.*
- **Phase 1 (me, via your Shell):** `object_storage:status` → `DRY_RUN=1
  object_storage:migrate` → `object_storage:migrate`. Copies every blob and
  flips each as it lands; the site serves throughout. *Rollback: nothing has
  moved for the app yet.*
- **Phase 2 (you + me):** set `ACTIVE_STORAGE_SERVICE=bucket`, redeploy, then
  sweep (`migrate` again), `verify` → `verify OK`, and the five-point smoke.
  *Rollback: unset the var, redeploy, `object_storage:rollback` — a pure
  metadata flip, because nothing was deleted from the disk.*

**Leave the disk attached.** It is the rollback.

### 4. Pre-scale and configure production (you) — ~10 min

- Web service → Compute → **12 CPU / 24 GB**, Manual Scaling **1**, autoscaling
  **off**. (~$450/mo while scaled; scale back after.)
- Environment: `WEB_CONCURRENCY=12` (one worker per core — this is what run 28
  measured), `RAILS_MAX_THREADS=5`.
- Confirm `REDIS_URL` points at `vertonow-infra`, now 1 GB / 1,000 connections
  with **Persistence Mode Off**.
- Set `SENTRY_DSN` if it is still unset, and `PLAYER_RATE_LIMIT_SCALE`
  generously for the event window (venue NAT concentrates many respondents on
  few IPs). Restore it afterwards.

*Rollback: every one of these is a dashboard field.*

### 5. Verify production (me) — ~15 min

- `/up` 200; `/up/storage` (reports "mounted" for any non-local service).
- The CSP header carries the bucket host in `img-src` **and** `connect-src`.
- A card image URL in the play page HTML is a presigned
  `…r2.cloudflarestorage.com/…X-Amz-Signature=…` URL, not a `/rails/…` path,
  and fetching it returns 200 with `Cache-Control: public, max-age=31536000`.
- The logo renders; a fresh upload in the editor lands on `bucket`.
- One full manual play of a real Verto: consent → progress → submit →
  leaderboard.

### 6. Go/no-go

**Go** requires all of: the five gates green in step 1; `verify OK` and the
smoke passing in step 3; the box on 12c-24g with `WEB_CONCURRENCY=12`; and step
5 clean. Any failure stops the cutover — production is left on whatever the
last good state was, which at every stage above is a working site.

## Event day

Detail in `docs/SCALE_AND_COST_PLAN.md` §4. The sequence:

1. **Freeze deploys** — turn off auto-deploy on the web service.
2. **`MEMORY_WATCHDOG_RESTART_PERCENT=0`** for the window (log only, never
   restart mid-burst).
3. **Pre-warm ~30 min before doors:**
   `TOKEN=<event verto> bin/rails load_test:prewarm` — builds the leaderboard
   snapshot and warms the page cache so the first arrivals do not pay the cold
   render. Run it twice; the second run confirms the cache is hot.
4. **Watch:** web CPU/memory, database CPU/connections, Key Value CPU, Sentry.
5. **Degrade order if needed:** live-results broadcast off first
   (`Rails.cache.write("degrade:results-broadcast", true)` — no deploy, no
   restart); the leaderboard is respondent-facing and stays.
6. **After the burst:** `VACUUM ANALYZE responses`, read out the results, then
   scale the box back down and restore `PLAYER_RATE_LIMIT_SCALE` and the
   watchdog.

## Outstanding

- **The event Verto** — create and publish on production, send the publish
  token. Needed only for the pre-warm and the final smoke, so it can arrive as
  late as event morning; by Wednesday evening lets us rehearse the pre-warm
  against the real thing.
- **Scratch teardown** — scale `vertonow-scratch-kv` and the scratch web box
  back down once no further runs are wanted.
