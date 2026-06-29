# Tier 3 — Move uploaded images to object storage (deferred)

> Status: **Stage 1 shipped** (gated, no production effect until R2 is wired).
> Stages 2–3 are **not started** — picked up later, not today.

## Why
Uploaded images are stored as base64 data URLs — survey backgrounds in
`surveys.background_image` (TEXT) and card images inside the `cards` JSON
(`card["image"]`, `option_images`). The bytes are re-materialised on every
editor/player render and ride along in the autosave PATCH, which is the last
remaining memory hot path after Tiers 0–2. Moving uploads to object storage
(Cloudflare R2) puts a short URL on the row/HTML instead of the bytes, and —
with variants — finally fixes the original "backgrounds don't display well
across devices" feedback.

## Decided approach (optimal)
- **Cloudflare R2** (S3-compatible, **zero egress**, durable, CDN-able). Not S3
  (egress cost on a public player), not a Render disk (pins to one instance, no
  edge cache).
- **Direct-to-R2 uploads** via Active Storage `DirectUpload` so the 512 MB web
  process never handles image bytes (kills the upload memory spike too).
- Move **both** backgrounds and card images; store blob URLs in the JSON.
- **libvips variants** for responsive backgrounds (closes the cross-device
  feedback). libvips is already in the Dockerfile.
- **Orphan-blob cleanup** sweep for replaced/removed images.
- Keep accepting legacy `data:` URLs during the transition — no flag day.

## Stage 1 — DONE (commit on branch `claude/survey-testing-feedback-c792jn`)
- `aws-sdk-s3` (lazy) + `image_processing` gems.
- `config/storage.yml` `cloudflare` service reads `R2_*` env.
- `config.active_storage.service` gated by `ACTIVE_STORAGE_SERVICE` (defaults to
  `:local`, so deploys stay safe); `variant_processor = :vips`.
- `Survey has_one_attached :background_file`.
- `surveys#update` transparently offloads a base64 background to Active Storage
  and stores the blob URL — **only when durable storage is configured**; on the
  ephemeral local disk in production it keeps base64 in the row, so backgrounds
  never vanish on redeploy. `sanitize_background_image` accepts blob URLs.
- `rails backgrounds:migrate` backfills existing base64 backgrounds.
- `render.yaml` has `ACTIVE_STORAGE_SERVICE` + `R2_*` placeholders.
- Tests: `test/integration/background_upload_test.rb`, sanitizer test in
  `test/models/survey_test.rb`.

## R2 provisioning (prerequisite for any production effect)
1. Create an R2 bucket (e.g. `playverto-uploads`).
2. Create an R2 API token (Object Read & Write).
3. Set in Render:
   - `ACTIVE_STORAGE_SERVICE=cloudflare`
   - `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`
   - `R2_ENDPOINT=https://<account-id>.r2.cloudflarestorage.com`
   - `R2_BUCKET=<bucket name>`
4. Add a CORS rule on the bucket allowing the app origin (needed for Stage 3
   direct uploads).
5. After deploy: `rails backgrounds:migrate` once.

## Stage 2 — card images → blob URLs (TODO)
- `has_many_attached :images` on Survey (owns the blobs).
- Offload base64 card `image` / `option_images` to blobs and store the blob URL
  in the `cards` JSON (same pattern as the background offload in `update`).
- Extend the sanitiser/validation for card image refs.
- Backfill task for existing base64 card images.
- Fully server-side and testable (no R2 needed to build/verify).

## Stage 3 — direct uploads + variants + cleanup (TODO, needs R2 + browser)
- Pin `@rails/activestorage`; use `DirectUpload` in `media_picker_controller`
  so the browser uploads straight to R2; only the blob signed-id returns to
  Rails. Requires the bucket CORS rule.
- Generate responsive background variants via libvips; reference the right one
  per viewport (closes the cross-device feedback).
- Periodic orphan-blob sweep (purge blobs no survey references).
- Optionally switch stored URLs to public/CDN URLs instead of the same-origin
  redirect path, for edge caching.

## Open decisions
- Merge cadence: Stage 1 is safe to merge to `Main` now (no behaviour change
  pre-R2), or bundle all of Tier 3 into one merge.
- Whether to serve via Active Storage redirect (simplest, same-origin) or a
  public R2/CDN domain (fastest, needs a custom domain).
