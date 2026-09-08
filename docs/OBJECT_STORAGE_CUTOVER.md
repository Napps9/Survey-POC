# Active Storage: disk → object storage cutover

Moves every upload (organisation logos, the brand asset library, card images
and their variants, report PDFs, Verto build files, comms images) from the
Render persistent disk to a shared S3-compatible bucket — **Cloudflare R2, EU
jurisdiction** (or AWS S3 `eu-central-1`) — with the app running throughout.

**Why.** A Render service with a persistent disk cannot run more than one
instance, and the worker cannot see that disk at all. Run 21
(`docs/SCALE_AND_COST_PLAN.md` §2b) showed Render's largest single box (12 CPU)
serves the 83/s event with zero errors but at ~2 s page loads; sub-second needs
a second box, and a second box needs uploads on storage every instance can
reach. This is the "disk unpin".

**Residency.** The bucket lives in the EU (R2 jurisdiction `eu`, or S3
Frankfurt), alongside the Frankfurt web service and database.

## What the code does (shipped on the scale branch, 2026-09-08)

| Piece | Where | Behaviour |
|---|---|---|
| `bucket` service | `config/storage.yml` | S3 service driven by `STORAGE_*` env. `request_checksum_calculation: when_required` (R2 rejects the SDK's default CRC32), path-style addressing when an endpoint is set, `Cache-Control: public, max-age=1y, immutable` on every object (keys are content-addressed). Parsed at boot, instantiated only when referenced — inert while `STORAGE_BUCKET` is blank. |
| The switch | `config/environments/production.rb` | `config.active_storage.service = ENV.fetch("ACTIVE_STORAGE_SERVICE", "local")`. Unset = the disk, exactly as before. |
| `ObjectStorage::Migrator` | `app/lib/object_storage/migrator.rb` | Per blob: copy the bytes (checksum verified on read and on write), then flip `active_storage_blobs.service_name`. Nothing is deleted from the source, so rollback is a metadata flip. Idempotent and resumable. Variants are blobs, so they come along. |
| Rake tasks | `lib/tasks/object_storage.rake` | `object_storage:status` · `object_storage:migrate` (`DRY_RUN=1`) · `object_storage:verify` · `object_storage:rollback`. `FROM`/`TO` default `local`/`bucket`. `migrate` exits non-zero on any failed or missing blob. |
| CSP | `config/initializers/content_security_policy.rb` + `lib/object_storage_origins.rb` | The bucket's origin is added to `img-src`, `media-src` and `connect-src` at boot whenever `STORAGE_BUCKET` is set. Card images are **redirect-mode** URLs (`rails_blob_path`): on the bucket each answers a 302 to a presigned bucket URL, and the browser checks CSP against that target too. The logo is proxied (same-origin) and needs nothing. |
| Service worker | — | No change and no `CACHE_VERSION` bump: its same-origin Active Storage handler returns whatever the fetch returns; a redirected image arrives opaque, renders, and simply isn't offline-cached. |
| `render.yaml` | web + worker | The six vars declared (`sync: false` on web, `fromService` on the worker). The `disk:` block is deliberately still there — see phase 3. |

Stored URLs never change: cards keep `/rails/active_storage/blobs/redirect/…`
paths and the dashboard draws the logo through `/rails/active_storage/blobs/proxy/…`;
both resolve per blob to whichever service holds it. No stored content is
rewritten. The public player alone swaps them for presigned bucket URLs at
render time — see "Player assets and the page cache" below.

## Env vars

| Var | Scratch / production value | Notes |
|---|---|---|
| `STORAGE_BUCKET` | `vertonow-scratch-storage` / `vertonow-storage` | |
| `STORAGE_ENDPOINT` | `https://<account-id>.eu.r2.cloudflarestorage.com` | Copy the **S3 API** endpoint from the bucket's settings page. Omit for AWS S3. |
| `STORAGE_REGION` | `auto` | R2's region. `eu-central-1` for AWS S3. |
| `STORAGE_ACCESS_KEY_ID` / `STORAGE_SECRET_ACCESS_KEY` | R2 API token, **Object Read & Write, scoped to that one bucket** | Shown once when created. Never in chat, never in git. |
| `ACTIVE_STORAGE_SERVICE` | **unset** until phase 2, then `bucket` | The switch. |

On production the worker takes all six `fromService` (render.yaml), so setting
them on the web service is enough once the worker exists.

## The cutover, staged

Rehearse every phase on **scratch** first (its own bucket, its own disk); then
production, on a quiet day, with the editor quiet (uploads made mid-copy are
harmless — a second `migrate` sweeps them — but fewer moving parts is better).

Where a step says *shell*: **Render dashboard → the web service → Shell**. That
is a shell **on the running instance**, which is the only place the disk is
mounted — a one-off job does not mount it, and the migration has to read from
it. `bin/rails …` there runs with the service's env.

### Phase 0 — configure (reversible: unset the vars)

1. Deploy this code (Main → production).
2. Create the bucket (EU jurisdiction) and a bucket-scoped read/write token.
3. Set the **five** `STORAGE_*` vars on the web service. Leave
   `ACTIVE_STORAGE_SERVICE` unset. Let it redeploy.
4. Check `/up` still 200, and the CSP header on any page now carries the
   bucket host in `img-src` (`curl -sI https://app.playverto.com/ | grep -i content-security`).
5. Shell: `bin/rails object_storage:status` — every blob on `local`,
   "app writes new uploads to: local".

### Phase 1 — copy (reversible: nothing has moved for the app yet)

Shell:

```
DRY_RUN=1 bin/rails object_storage:migrate   # counts only, touches nothing
bin/rails object_storage:migrate             # copies + flips each blob as it lands
bin/rails object_storage:status
```

A blob is served from the disk until the instant its copy is verified, and
from the bucket right after, so the site keeps working mid-run. Re-run
`migrate` at any time; it only does what is left.

Read the summary line. `missing=N` means N blobs whose bytes were **already
gone from the disk** (they 404 today; they were left on `local` and still 404 —
nothing regressed). `failed=N` is a copy or checksum problem: fix and re-run
before going on. `verify` will still fail here if uploads kept landing on the
disk after the run — expected, it is what phase 2's second `migrate` is for.

Smoke: open a dashboard with a logo, a Verto with card images, the brand
library — all still render (they now stream from the bucket through the same
URLs).

### Phase 2 — switch (reversible: `rollback` below)

1. Set `ACTIVE_STORAGE_SERVICE=bucket` on the web service (the worker inherits).
   Redeploy.
2. Shell: `bin/rails object_storage:migrate` — sweeps anything uploaded to the
   disk between phase 1 and the redeploy — then
   `bin/rails object_storage:verify`, and `object_storage:status` → "app writes
   new uploads to: bucket".

   **`verify OK` is only reachable on a store with no pre-existing damage.**
   It returns OK when *zero* blobs are left on `local`, but a blob whose bytes
   were already gone is deliberately left there (it 404s either way), so on a
   store that has lost files `verify` reports the count and returns false
   forever. That is not a failed migration. The real pass condition is **no
   blob left on `local` that is still readable**, which is what the migration
   could have moved and didn't:

   ```
   bin/rails runner 'local = ActiveStorage::Blob.services.fetch(:local); \
     bucket = ActiveStorage::Blob.services.fetch(:bucket); \
     left = ActiveStorage::Blob.where(service_name: "local").to_a; \
     unmigrated = left.count { |b| local.exist?(b.key) }; \
     sample = ActiveStorage::Blob.where(service_name: "bucket").order(Arel.sql("RANDOM()")).limit(50).to_a; \
     present = sample.count { |b| bucket.exist?(b.key) }; \
     puts "left on local: #{left.size} (still readable = NOT migrated: #{unmigrated}); bucket sample: #{present}/#{sample.size}"'
   ```

   Pass is `still readable: 0` and a full sample.
3. Smoke, in this order:
   - a play page: logo renders (proxy route, 200);
   - a card image URL from that page's HTML: it is a presigned
     `…r2.cloudflarestorage.com/…X-Amz-Signature=…` URL, and fetching it → 200
     with `Cache-Control: public, max-age=31536000, immutable`. Pick a Verto
     whose card art was **uploaded**: art chosen from Pexels stays an
     `images.pexels.com` URL and is passed straight through, so such a page
     shows neither a bucket URL nor a `/rails/…` path and proves nothing;
   - the CSP header contains the bucket host in `img-src` **and** `connect-src`;
   - upload a fresh logo/card image in the editor → it appears, and
     `object_storage:status` shows the new blob on `bucket`.
4. Leave the disk attached and stay here for a while (a day on production).
   Everything is now multi-instance safe **except** that the disk still pins
   the service to one instance.

**Rollback (phase 2):** unset `ACTIVE_STORAGE_SERVICE`, redeploy, shell:
`bin/rails object_storage:rollback` — flips back every blob the disk still
holds a copy of. Blobs uploaded *while on the bucket* have no disk copy and are
deliberately left on `bucket`; they keep working as long as the `STORAGE_*`
vars stay set, so **do not clear those** on a rollback.

### Phase 3 — unpin (NOT reversible: the disk's contents are destroyed)

Only after phase 2 has been live and verified.

1. Remove the `disk:` block from `render.yaml` (and its comment), merge, let
   Render detach the disk. The `/up/storage` check reports `mounted: true` for
   any non-local service, i.e. "not applicable".
2. Two-box fleet, in this order:
   - the worker service exists and is processing (blueprint sync or dashboard;
     `render.yaml` has the full definition);
   - `RUN_SOLID_QUEUE_IN_PUMA=0` on the web service (queue and recurring tasks
     now run exactly once, in the worker — never in N web instances);
   - web instances → 2 (or whatever the proof run calls for), same compute plan.
3. Re-run the branded proof against the fleet (`IMAGES=` seeded Verto).

## Player assets and the page cache (post-cutover behaviour)

Once `ACTIVE_STORAGE_SERVICE=bucket`, the public player changes two things, both
measured necessary by runs 22–23 (`docs/SCALE_AND_COST_PLAN.md` §2b):

- **Card images and the logo are presigned bucket URLs in the page**
  (`app/lib/player_asset_urls.rb`): a respondent's browser fetches them from the
  bucket directly and Rails never sees an image request — on the disk each was
  a 302 or a proxied stream, 60% of all web requests on a six-image deck. URL
  TTL 2 h ≥ 2 × the page-cache TTL, pinned by a test; anything unresolvable
  passes through as the old same-origin path, so a broken presign degrades
  rather than fails. Editor, preview and dashboard are unchanged. This is why
  the bucket origin is in the CSP (phase 0), not only for the 302s.
- **The play page has a process-local front cache**
  (`PlayerController.player_page_local_cache`) in front of `Rails.cache`: one
  render per Puma worker per hour per key, and a Key Value blip no longer means
  every request re-renders. Keys are unchanged and expiry-only, so republish
  busting works exactly as before.

The phase-2 smoke therefore also checks that a card image URL in the play page
HTML is an `https://…r2.cloudflarestorage.com/…X-Amz-Signature=…` URL (not a
`/rails/active_storage/…` path) and that the logo `<img src>` is likewise.

## Costs and notes

- **R2**: no egress fees; storage cents. **S3 Frankfurt**: egress billed — at
  50k respondents × ~10 card images × ~100 KB that is ~50 GB per event.
- Per-image cost on the web tier is a 302 (one primary-key lookup + a presign,
  ~1–2 ms); the bytes go browser ↔ bucket. Browsers cache each image for a year.
- k6 follows the 302, so `endpoint:image` timings in `journey.js` include the
  bucket fetch. Seed scratch with `IMAGES=N` so the proof run loads real
  attachments — every run before 22 measured a text-only deck.

## Production record — 2026-09-08

Phases 0–2 ran on production the evening before the event cutover; phase 3 is
deliberately not done (see above). What the run found, kept here because the
numbers are the argument for the corrected gate:

- **562 blobs, of which 291 had no bytes on the disk.** Not caused by the
  migration and not fixed by it: everything created up to `id 304 @ 2026-08-19
  08:23 UTC` was gone, everything from `id 305 @ 2026-08-19 11:36 UTC` intact.
  That is the morning the persistent disk was attached — before it, `storage/`
  lived in the container and was wiped on every deploy. Those 291 are 404s
  today and stay 404s; they are org logos and card art from before that date
  and the only repair is re-uploading the originals.
- **271 copied, 0 failed**, then `still readable: 0` and a 50/50 bucket sample.
- Presigned fetch: 200, `public, max-age=31536000, immutable`.
- CSP carried the bucket host in `img-src`, `media-src` and `connect-src`, both
  path-style and virtual-hosted.
- A play page with uploaded card art emitted 9 presigned URLs and no
  `/rails/active_storage/…` paths; a fresh editor upload landed on `bucket`.

Two practical notes for the next store:

- `curl` from a machine outside the network may not reach the app at all; every
  check above runs from the service's own Shell against `http://localhost:10000`
  with `-H "Host: <domain>" -H "X-Forwarded-Proto: https"`, which satisfies
  host authorisation and `force_ssl`.
- Do the credential pre-flight *before* phase 1 — one `upload`/`download`/
  `delete` round trip through `ActiveStorage::Blob.services.fetch(:bucket)`.
  It proves key, secret, endpoint, jurisdiction and token scope in one shot,
  at the one moment when nothing depends on the answer.
