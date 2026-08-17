# Playverto — user-feedback backlog

## Context

~18 items from user feedback across four areas: two production errors breaking
users now, missing editor affordances (rename, unpublish, undo), the
consent-gate story, and a tokenisation cluster. They are not independent — the
consent-gate and welcome-card items share a root cause, and the tokenisation
items share one config surface — so they are sequenced by dependency below,
not by the order raised.

Three findings reframe the work before anything is built:

1. **The consent gate is not a card.** It is survey columns (`consent_text`,
   `consent_image*`) rendered as a pseudo-card at player index 0. That one fact
   explains three separate reports: it can't be reordered against the welcome
   card (it has no position), it can be added after publishing (it saves via
   `update_settings`, the only content endpoint with no `published?` guard),
   and it can't carry text screens (it isn't in the card pipeline at all).

2. **The editor's source of truth is the DOM.** `serialize()`
   (`survey_editor_controller.js:739-918`) rebuilds the cards array by reading
   live DOM on every save, and there is no render-from-JSON path — new card
   markup is always minted server-side via `POST /surveys/:id/render_card`.
   This is the governing constraint on undo.

3. **The tokenisation back-nav rule is already correct on the server and wrong
   on the client.** No new server work is needed for it.

Verified against `54d6742` on `Main`.

## Decisions taken

| Question | Decision |
|---|---|
| Multi-screen consent | **New separate card type**; today's simple gate stays |
| Undo depth | **Both** — in-session Cmd+Z *and* restore that survives reload |
| Respondent code | **Per-Verto only** |
| First build phase | All four clusters below (1a–1d) |

---

# Phase 1a — Production errors

First: the only items actively breaking users, and the 502 work touches
endpoints later phases also edit.

## 502 Bad Gateway

Production is **one Ruby process, 3 Puma threads** + 2 job threads on a 512 MB
box (`config/puma.rb:22-23,30`, `render.yaml:10-12,55-56`). No `rack-timeout`,
no `worker_timeout` — nothing bounds a request. Occupying 3 threads downs the app.

**Confirmed driver — quadratic inline translation.** `#generate_flow`
(`surveys_controller.rb:628-657`) maps every generated card through
`translate_card!` (`:986-996`), which loops every secondary locale issuing **one
Claude call per card per locale**. A 6-card flow on a 5-language Verto = 1 + 30
sequential calls at 120 s each (`render.yaml:93-96`). One editor action can hold
a thread for the better part of an hour. `#generate_card` (`:601`) and
`#optimise_card` (`:668`) have the same shape at 1 + N.

Fix in order:
1. **Batch the translation.** `SurveyTranslator#call` already accepts `cards:`
   as an **array**; `translate_card!` passes `[card]` one at a time. Pass the
   whole generated deck once per locale — 30 calls become 5. Highest
   value-per-line change in this document.
2. **Move the remainder off the request thread**, reusing the existing
   `VertoBuild` + `BuildVertoJob` pattern and the `/verto_builds/:id` poller.

Same pass:
- `#resume_import` (`:165` → `create_imported_survey!` `:886-887`) runs a full
  `translate_survey!` **and** `auto_populate_assets!` inline. `BuildVertoJob`
  stops short and hands it back to a request thread — finish the job's remit.
- `PlayerController#grade` → `ai_normalize_open_ended_answer!`
  (`player_controller.rb:435`) makes a Claude call from a **public,
  unauthenticated** endpoint; respondent traffic on a live quiz can exhaust all
  3 threads. Needs the `LimitsConcurrentStreams` bulkhead
  (`concerns/limits_concurrent_streams.rb`) or a job.
- `ResultsReportsController#show` and `GoogleDriveExportsController#create` both
  call `results_report_markdown` (`concerns/generates_results_report.rb:13-29`),
  which generates inline on a cold cache and is **not** covered by the bulkhead.
- Inline libvips variants (`application_helper.rb:311-316`) fire up to 60
  concurrent transforms on first load of the branding page
  (`memberships/index.html.erb:76`) — a memory spike nothing serialises.
- Add **`rack-timeout`** (open as P1-5, `docs/PRODUCTION_READINESS_PLAN.md:82`).

**Diagnosis note:** a 502 from thread exhaustion or an OOM kill never reaches
Rails, so **Sentry shows nothing**. Confirm from Render HTTP logs plus the
`MemoryWatchdog: container using N MB of N MB (N%)` line logged every 30 s
(`lib/puma/memory_watchdog.rb:86-87`). Also correct the stale comments in
`verto_builds_controller.rb:12-13` and `report_renders_controller.rb:30-31`
claiming "85% RSS" — the real rule is 90 % of the **cgroup** limit sustained
over two 30 s samples (`lib/puma/plugin/memory_watchdog.rb:26,30`).

## 400 on brand image upload

**Not diagnosable from code alone — stop swallowing it first.** There is no
`render status: :bad_request` anywhere in the repo and no `public/400.html`, so
the 400 is framework-level, and the client hides which one:
`logo_uploader_controller.js:41` calls `await res.json()` **outside any status
check**. A 400 (empty/HTML body), a 302 from `require_admin!`, or a 500 all make
it throw; `catch (_e)` at `:48` swallows it and shows a generic
**"Couldn't save"**. That is very likely why this arrives as a bare "400".

1. **Surface the real error.** Branch on `res.status`, only parse JSON when the
   content-type says so, show status + server message. Everything below is
   guesswork without this.
2. **Remove the one 400-producing construct.** `params.require(:organisation)`
   (`organisations_controller.rb:19`) raises `ActionController::ParameterMissing`
   → **400**, unrescued, whenever the multipart body fails to parse or the field
   is absent. Use `params.fetch(:organisation, {}).permit(...)` and return a JSON
   422 so the client always gets a parseable body.
3. **Pre-validate client-side.** `upload()` (`:15-22`) sends any file with no
   size or type check against a 2 MB / images-only model cap
   (`organisation.rb:27-28`).
4. **Brand-asset library** (`assets[]`, `organisation_assets_controller.rb:12`)
   has no strong params; selecting more than Rack's 128-part multipart limit
   400s *before* the friendly 60-asset message at `:17-20` runs. Cap client-side.

Residual candidates once instrumented: Rack multipart parse failure from a
non-UTF-8 filename (common with design-tool exports), or a truncated body.

---

# Phase 1b — Quick editor wins

**Rename a Verto in the editor (S).** The plumbing is already inert-but-present:
`serialize()` returns `title: this.titleValue` (never reassigned) and `#update`
already accepts `payload["title"]` (`surveys_controller.rb:271`). Add a
`contenteditable` title to the editor chrome (`surveys/show.html.erb:145-223`),
reusing the `gate_cards_controller.js` inline-edit pattern (`queueConsentSave`
:85 debounce, `blockEnter` :112, `_focusEnd` :144), and assign `titleValue` on
input so autosave carries it. **Caveat to settle:** the dashboard displays
`theme.presence || title.presence` (`_dashboard_card.html.erb:41`), so renaming
`title` alone won't change the visible name. Recommend flipping `verto_name` to
`title.presence || theme.presence` — the wizard already promises this
(`surveys/new.html.erb:104-105`) — and keeping `theme` as the AI brief subject.

**Unpublish a live Verto (M).** Publishing is one-way today: only
`POST surveys/:id/publish` exists, and nothing ever nils `publish_token`
(which *is* the `/play/:token` key). Recommended semantics, because reverting a
Verto with responses to an editable draft would corrupt data — answers are keyed
by **card index**, so editing after responses exist silently misaligns them:

- **No responses** → full revert to draft, unlocking editing. Keep
  `publish_token` so re-publishing restores the same link (QR codes, print).
- **Has responses** → **close** it: stop accepting new responses, keep results,
  keep questions locked. Re-open restores.

Implement as `surveys.unpublished_at`; `published?` becomes
`publish_token.present? && unpublished_at.nil?`. The player already has a
branded `player/unavailable.html.erb` for unreachable links (commit 8116ab6) —
route closed Vertos there.

**Delete a welcome card (S).** One template conditional suppresses delete,
duplicate *and* reorder for welcome cards: `_card_row.html.erb:66` (closing
`:111`). Remove the delete suppression (and the reorder suppression — needed
anyway so the welcome card can move around the consent card). There is
currently **no server-side guard at all**, and `welcome_card` is
`pickable: true`, so a second one can be added and any card converted into one.
Add the missing server rule (at most one welcome card) in
`Survey.sanitize_cards_images!`, and drop `welcome_card` from
`CardTypes.pickable_for` when the deck already has one.

**Disambiguate the delete CTAs (S).** Three visually identical
`.card-delete-btn`s exist: per-card delete (`_card_row.html.erb:103-110`),
consent "Remove" (`show.html.erb:250-253`), thank-you "Remove" (`:341-344`).
Name each target — `Delete card 3` (the `Card N` pill is already on the same
row), `Remove consent gate`, `Remove thank-you screen` — and add matching
`title` attributes. Also fix the genuinely dangerous fallback at
`type_panel_controller.js:895-897`: a delete button not inside a card falls back
to `this.activeCardEl`, i.e. it deletes *whatever is selected* with no visual
tie. Make the sidebar delete name its target or drop the fallback.

> **Open:** there is **no CTA labelled "redirect"** anywhere in the editor —
> grep of views, JS and locales returns nothing. The nearest concepts are
> per-end-screen `forward_url`/`forward_label` (`_end_screen_row.html.erb:15-20`)
> and `Survey#forward_url`, which `update_settings` accepts but **no editor field
> writes**. Needs one clarification from the user before building (see
> Open Questions).

---

# Phase 1c — Consent gate cluster

**Fix "consent can be added after publishing" (S).** `update_settings`
(`surveys_controller.rb:432`) is the only content endpoint with no `published?`
guard, while `update`, `card_image`, `shuffle_assets`, `generate_card`,
`generate_flow`, `optimise_card` and `render_card` all have one. A blanket guard
is wrong — the action also handles post-publish-legitimate fields. Add a
per-field carve-out:

- **Locked when live:** `consent_text`, `consent_image*` (they change what
  respondents agree to mid-flight and leave `consent_text_snapshot` nil on
  earlier responses), `tokenisation_enabled`, `token_types` (they change scoring).
- **Stays editable:** `show_results_comparison`, `compare_note`, `slug`,
  `end_screens`, `forward_url`.

Two tests currently pin the old behaviour and must change:
`test/integration/consent_gate_test.rb:26-39` builds a **published** survey and
asserts consent saves — switch it to a draft and add a new test asserting
rejection when live. `test/integration/live_verto_lock_test.rb:78-83` only
exercises `show_results_comparison` + `compare_note`, which stay editable, so it
passes unchanged.

**New multi-screen consent card type (M).** Reuse the scenario machinery
wholesale — it already solves every sub-problem:
- New `consent_gate` type in `config/card_types.yml`; add to
  `CardTypes::NON_QUESTION_TYPES`.
- Stores `pages: [{id, text}]` exactly like scenario. Extend the sanitizer at
  `survey.rb:387-405` (today type-gated to `"scenario"`) to cover it, inheriting
  `MAX_SCENARIO_PAGES`/`MAX_SCENARIO_PAGE_LENGTH` and the **id-keyed i18n**
  re-mapping that keeps translations aligned when pages are reordered.
- Editor: mount the existing `scenario_controller.js` with `editableValue: true`;
  markup follows `_card_component.html.erb:325-416`.
- Player: reuse `scenario_controller.js` for the page turns and record agreement
  through the existing `PlayerController#consent` endpoint (`:123-146`) so
  `consent_agreed_at` / `consent_text_snapshot` still populate.
- **Answer-index safety:** as a real card it consumes an index, which would shift
  every later card's answer key. That is safe *only* because cards cannot be
  added to a live Verto — which is exactly the hole Phase 1c closes first. Build
  the guard before the card type, not after.

**Welcome card before/after the consent gate (S).** For the new card type this
is just card ordering — free, once the welcome card's reorder buttons are
un-suppressed in Phase 1b. Recommend **not** building a `consent_position`
column for the legacy column-based gate: it would be a throwaway mechanism for a
feature the new card type supersedes. Leave the legacy gate pinned first and
document that ordering requires the new card.

---

# Phase 1d — Tokenisation cluster

All six touch player-rendering files → **bump `CACHE_VERSION`**
(`app/views/pwa/service-worker.js:20`, currently `playverto-v9`).

**Move the token pill off the welcome card (S).** Rendered at
`player/_welcome_intake.html.erb:16-29`, mounted from
`_card_component.html.erb:606-609` under `when "welcome_card"`. Add
`surveys.token_intro_cid` (defaulting to the welcome card) and render the intro
block on whichever card matches. Editor control in the Tokenisation tab
(`surveys/show.html.erb:645-717`).

**Per-answer token score reveal (M).** `_applyTokenEarn`
(`player_controller.js:1452-1468`) already computes the per-card earned amount
and discards it into the running total — capture and render it. Reuse the quiz
reveal pattern verbatim: `_revealCard()` (`:1275-1300`), `.quiz-reveal` CSS
(`application.css:5443-5472`), `@keyframes quiz-reveal-in`. Gate on a new
`surveys.token_reveal_enabled`.

**Explicit per-question on/off (S).** Today "off" is implicit — all amounts zero,
and `_tokenAmounts()` (`survey_editor_controller.js:988`) drops zeros. Add a
per-card `tokens_enabled` key; `TokenGrading.awarding?` (`token_grading.rb:40`)
returns false when it is explicitly `false`. Absent key = enabled, so existing
decks are unaffected. Editor switch on the card's token block
(`_card_component.html.erb:684-750`).

**Backward-navigation rule (S) — a client bug, not a feature.** The server is
already right: `locked_merge` (`player_controller.rb:392-404`) keys off
`answered?(stored[key])`, so an unanswered tokenised card already accepts new
input. The **client is stricter than the server**: `_applyTokenEarn` fires on
*leaving* a card regardless of whether it was answered, adds it to `_tokenLocked`
and disables the inputs. Fix: only lock when that card actually has a non-blank
captured answer, mirroring the server's `answered?`. Then back-nav to an
unanswered tokenised card leaves it editable, while any card that awarded tokens
stays locked — exactly the documented promise in `player.tokens_welcome_note`.
Add `surveys.token_back_nav_enabled` (default **false**, preserving today's
behaviour) as the creator opt-in.

**Configurable Share (S).** `player/show.html.erb:240-245` renders
unconditionally. Add `surveys.share_enabled`, **default true** — it is on for
everyone today, so defaulting false would silently remove a live feature. Toggle
in the Publish & share panel.

**Configurable Compare regions (S).** `PlayerController#regions` (`:287`) is on
for every published Verto by design. Add `surveys.regions_enabled` (**default
true**), gate the CTA, and return 403 from `#regions` when off — mirroring how
`#results` already 403s without `show_results_comparison` (`:269-271`).

---

# Phase 2 — Remaining items

**Undo, both layers (L).**
*In-session Cmd+Z* must be **operation-based, not snapshot-based**, because
there is no deserialize path. Keep an inverse-op stack in
`survey_editor_controller.js`:
- *delete* → retain the detached `.card-slot` node in memory and re-insert it.
  This is the key insight: the node is the **same object**, so `this._store`'s
  element-reference keys survive intact. Must also un-park the quiz/token/logic
  blocks that `_parkSlotContents` (`type_panel_controller.js:936`) moves to the
  sidebar on delete.
- *reorder* → inverse move. *type change* → record the previous card JSON and
  re-render via `render_card` (async). *text edits* → leave to the browser's
  native contenteditable undo; don't intercept.
- Bind on the editor root, skipping when focus is in an input/contenteditable.
  Undo calls `markDirty()` like any edit, so the 1.5 s autosave persists it.
- **Explicit limit:** gates, end screens and token types save through
  `update_settings`, outside `serialize()` — they are *not* covered.

*Restore that survives reload* — two cheap pieces:
- **Deleted Vertos:** `deleted_at`, `archive!`, and `kept`/`archived` scopes all
  already exist (`survey.rb:26-27,493`). There is simply **no restore UI**. Add
  an Archived view with Restore (`update(deleted_at: nil)`). Highest value per
  line in Phase 2.
- **Deleted cards:** add a `surveys.deleted_cards` JSON ring buffer (last N
  removed cards + their index and timestamp), written on save when a card
  disappears from the payload, surfaced as "Recently deleted" in the editor.
  Far cheaper than a versioning gem and enough for the reported need.

**Respondent code, per-Verto (M).** Add `surveys.respondent_code_enabled` plus
optional prompt copy. Player collects a self-invented code before the first card
and stores **`responses.respondent_code_digest`** — an HMAC of the code with a
per-survey salt, never the plaintext, so the creator cannot read it and it is
only comparable within that Verto. Index `[survey_id, respondent_code_digest]`.
Repeat participation creates a **new** response row sharing a digest (the unique
index is on `session_token`, which stays the row key) — precisely what
longitudinal comparison needs. Creator sees "N respondents returned" and
wave-over-wave comparisons, never a code.

**Free-text character limit (S).** Today: hardcoded 200
(`_card_component.html.erb:595-603`), **advisory only** — no `maxlength`, no
server check anywhere, the counter just turns red. Add a per-card `char_limit`
(absent = 200), a creator control offering the current default plus smaller
presets, a real `maxlength`, and — new — server-side enforcement in
`PlayerController#progress`/`#submit`, which today write straight into the JSON
column untruncated. Applies to the "Other" box too (`:828-834`).

**Scenario page-turn visibility (S). SHIPPED.** Root cause found: the outgoing
page faded on a **0.38 s** opacity transition while its rotation ran **0.5 s**,
so it was fully invisible before the turn finished — you only ever saw the
first ~75 % of the arc, already fading. Fixed: the outgoing page's fade now
waits, then finishes with the rotation (`.book-page.is-turning`,
`application.css:2644-2646`, 0.52 s transform / 0.3 s opacity delayed 0.22 s),
the outgoing rotation was softened to `rotateY(-104deg)`, and the incoming page
was given more travel (`scenario_controller.js#layout`). The **deck** advance
also gained the animation it was missing (`.preview-card.is-entering`,
`application.css:5112-5121`), closing the instant jump on the last tap of a
scenario card and on every ordinary Next.
One residual inconsistency remained after that: the step **off** a scenario's
answer page still handed the next card the same snappy 0.26 s entry as any
other Next, right after the book's slower 0.52 s turn — a pace change,
mid-gesture. Fixed by giving that one transition its own slower entry
(`.preview-card.is-entering--from-book`, `application.css:5122-5125`,
`player_controller.js#_animateCardEntry`), applied only when the departed card
was a scenario. Covered by
`test/system/scenario_player_aria_test.rb`.
No `CACHE_VERSION` bump was needed for any of this — `/play` is served
network-first with an offline cache fallback (see `CLAUDE.md`), so player
content/CSS/JS changes reach respondents on their next ordinary online visit.
A bump is only required when the service worker's *own* behaviour changes.

---

# Verification

Per `CLAUDE.md`, all four gates must be green before every push to `Main`:

```
bin/rails test        # 883 tests currently
bin/rubocop
bin/brakeman --no-pager
bin/importmap audit
```

Plus, per phase:
- **502:** measure before/after Claude call counts for a multi-locale
  `generate_flow` (assert one call per locale, not per card per locale). Watch
  the `MemoryWatchdog` log line under load.
- **400:** drive the logo upload with an oversized file, a wrong type, and a
  non-UTF-8 filename; assert a JSON body and a human-readable message every time.
- **Consent/publish:** new integration test asserting `update_settings` rejects
  `consent_text` on a live Verto and still accepts `compare_note`.
- **Player changes:** use the `/verify` skill (seeded demo account + headless
  Chromium) for the consent card, token reveal, back-nav rule and page-turn.
  **Any player-rendering change requires a `CACHE_VERSION` bump** or it silently
  won't reach returning respondents.
- **Locales:** every new UI string must be added to all **19** files in
  `config/locales/`.

# Open questions — and how I'll proceed without answers

Both were raised with the user and left unanswered, so each has a stated
assumption. Neither blocks the rest of the work; both are cheap to change later.

1. **What is the "redirect CTA"?** No CTA with that label exists anywhere in the
   editor — grep of views, JS and all 19 locale files returns nothing. The
   candidates are the per-end-screen `forward_url`/`forward_label` fields
   (`_end_screen_row.html.erb:15-20`), the thank-you screen's `✕ Remove`, and
   answer routing.
   **Assumption:** I will disambiguate the three *delete* CTAs as described in
   Phase 1b (that part is unambiguous and confirmed), and additionally label
   each end-screen's forward-URL field with the end screen it belongs to — the
   most likely reading, and harmless if wrong. I will **not** restructure answer
   routing on a guess. Worth a 30-second confirmation before that sub-item ships.

2. **Unpublish semantics.** **Assumption:** the recommended split — a Verto with
   **no responses** reverts fully to draft and becomes editable again (keeping
   `publish_token` so the link survives); one **with responses** is *closed*
   (stops accepting responses, results kept, questions stay locked). This is the
   only option that cannot corrupt collected data, since answers are keyed by
   card index and editing a deck after responses exist silently misaligns them.
   If the user wants unpublish to always unlock editing, that is a one-line
   change to the same guard — but it should be a deliberate choice, not a default.
