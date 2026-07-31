# Bug log

Bugs found and fixed while hardening the platform, kept because several of them
share a shape worth recognising: **the obvious check said the code was fine.**

Each entry records what broke, how it was found, why the usual check missed it,
and what now stops it coming back. Newest first.

---

## BUG-020 — A closed Verto told respondents their answers were saved

**Severity:** silent, permanent loss of a respondent's completed response —
with an affirmative message saying the opposite.
**Found:** the boundary bug hunt; confirmed by three independent refuters.

The player HTML is served stale-while-revalidate, so a respondent can be part
way through a Verto that the creator has since unpublished or closed. On submit
the server correctly returns **410 Gone**. The service worker then did:

```js
const res = await fetch(req)
if (!res.ok) throw new Error(...)   // ← a 410 is not an outage
```

which fell into the offline branch: the answers went into IndexedDB and the page
got a synthesised `202 {ok: true, queued: true}`. The respondent was shown
**"Saved — will sync when you're back online."** Nothing was saved and nothing
ever would be — `drainQueue` deleted an item only on `res.ok`, so the 410 was
retried on every same-origin GET for the life of the browser profile.

The player could not have told the difference either: `if (!res.ok) throw` sent
a refusal and a network failure to the same `catch`, whose only question was
`navigator.onLine`.

**Fix, both halves:**
* the worker queues only when no response arrived at all, or the server asked to
  be retried (429/5xx). A 4xx is passed to the page unchanged. `drainQueue`
  drops an item on any non-retryable status, and gives up after
  `MAX_QUEUE_ATTEMPTS` so a submit that can never land stops costing battery on
  every page view;
* the player distinguishes *refused* from *queued* and says so, in all 19
  locales.

**Guard:** `test/system/submit_rejected_test.rb`, including the negative case —
a successful submit must show **no** pill, or an unconditional one would pass
every other assertion while telling every respondent their answers were lost.

`CACHE_VERSION` bumped to v21: without it no returning respondent would get the
fixed worker, which is the whole point of the rule.

---

## BUG-019 — An edit made during a save was marked clean by that save

**Severity:** silent loss of a creator's edit.
**Found:** the boundary bug hunt.

`_doSave` cleared `_dirty` *after* awaiting its response, so an edit typed while
a save was in flight — which `markDirty` had correctly flagged — was marked
clean by a request that did not contain it.

On its own that only delays the edit: `markDirty` re-arms the 1.5s timer. The
loss needs the page to go away inside that window, and `flushSave`, the
pagehide/visibilitychange safety net, opens with `if (!this._dirty) return`.
Typing something and immediately switching tabs is an ordinary thing to do.

**Fix:** a generation counter. `markDirty` bumps it; `_doSave` snapshots it
before serializing and only clears `_dirty` if it hasn't moved.

**Guard:** `test/system/autosave_race_test.rb` holds the PATCH open from the
test rather than sleeping, so "while the save is in flight" is a state under
control rather than a window being raced — a timing-dependent version would
pass on a fast machine either way. The second test cancels the re-armed timer
before flushing: without that it passed against the unfixed build, because the
ordinary debounced save landed the edit and `flushSave` was never the thing
being tested.

---

## BUG-018 — "✨ Optimise" destroyed eleven fields on the card it improved

**Severity:** data loss on a single click, including the card's identity.
**Found:** the same hunt, then confirmed by reconstructing the payload.

The editor sent one card to be rewritten as:

```js
card: { type: card.dataset.cardType, ...this._readCard(card) }
```

`_readCard` returns four keys. The server merges the AI's rewrite **onto**
whatever it is given and re-renders the card from the result, so everything
absent from that payload was absent from the card afterwards:

```
stored card : cid common_question_id common_question_set_id competency
              condition correct flow_id image logic options outcome required
              text tokens type
after       : options outcome pages text type
LOST        : cid common_question_id common_question_set_id competency
              condition correct flow_id image logic required tokens
```

The `cid` matters most: other cards' logic routes point **at** it, so
optimising a card silently orphaned every branch that led to it.

The server's own comment claimed *"competency/condition ride along from the
original card untouched"* — describing an intent the client made impossible, the
same way BUG-013's guard described protection it wasn't providing.

**Fix:** send `this.serialize().cards[idx]` — the card's complete current
object, and the same idiom `flows#duplicateCard` already uses.

**Guard:** `test/system/optimise_card_test.rb` asserts on the payload itself,
because the payload *is* the defect; it fails against the old shape. Its fixture
turns quiz and tokenisation **on**, because `serialize()` only emits `correct`
and `tokens` when they are — with them off the test would have passed while
proving less than it claimed.

**Lesson:** "merge the improvement onto the original" is only safe when the
original is the original. Here one side said merge and the other sent a
summary — and each side, read alone, looked right.

---

## BUG-017 — Every autosave stripped the framework tags off every card

**Severity:** silent, permanent loss of the provenance the "Why this card?"
panel exists to show — on cards the creator never touched.
**Found:** a bug hunt aimed specifically at the BUG-015 shape.

`SurveyGenerator` tags each generated card with the Awareness/Intention/Agency
competency it sits under, its enabling condition and a plain-language outcome.
`_card_row.html.erb:40-42` carries all three into the DOM, the editor renders
them in the Why panel, and `sanitize_cards_images!` preserves them perfectly.

`serialize()` never read them back. It rebuilds each card as `const out = { type }`
and adds only the keys it knows about, so the first autosave posted every card
without them and the panel emptied for the whole deck.

Proven by round trip rather than by reading:

```
sanitiser keeps competency? true  condition? true  outcome? true
after an editor round trip: ["cid", "options", "text", "type"]
```

**Fix:** carried through from `data-card-competency` / `-condition` / `-outcome`,
the way `common_question_id` and `range_theme` already are.

**And the half that came with it:** carrying a field from the client means the
server starts receiving it on a PATCH. `SurveyGenerator#normalize_framework!`
allowlists competency and condition, but that runs on *generation* — not on
save. Before this, a crafted PATCH could put any string in the Why panel and a
5,000-character outcome in the column. The sanitiser now applies the same
allowlist, and caps `outcome` (free text by design) at `MAX_OUTCOME_LENGTH`.

**Guard:** `test/system/framework_tags_test.rb`. The regression test edits a
*different* card, because that is the property that matters — `serialize()`
rebuilds the whole deck, so a gap in it destroys data on cards nobody opened.
Both round-trip tests fail against the unfixed build.

**Lesson:** every "carry this through" line in `serialize()` exists because
something was once lost. The list is not a feature list, it is a scar list —
and anything the DOM carries but `serialize()` omits is already lost.

---

## BUG-016 — The guard written for BUG-015 was shaped like BUG-015

**Severity:** one more blanked card type, and a test that read as coverage.
**Found:** the same hunt, immediately.

`token_checkpoint` is `pickable: true` whenever tokenisation is on and had no
entry in the type panel's `COMPONENTS` table, which falls back to `() => ""`.
Picking "Points Checkpoint" therefore emptied the card — the identical defect to
consent_gate, in the only other type that had it.

The parity test shipped with BUG-015 asserted *every paged type has a builder*.
That is the property the bug happened to have, not the rule. It passed the whole
time `token_checkpoint` was missing.

The same test banned `type === "scenario"` across a hand-written list of the two
files that had just been fixed — and so missed `lib/verto_rules.js`, which still
had it.

**Fix:** the table check now covers every **pickable** type, and the literal ban
scans every JS file under `app/javascript` (comments stripped, since
`paged_types.js` documents the banned pattern by quoting it).

**Lesson:** a guard written immediately after a bug tends to encode that bug's
incidental properties rather than the rule it violated. Ask what the rule is,
then check where else it could be broken — not where it *was* broken.

---

## BUG-015 — A consent gate that recorded no consent

**Severity:** the highest in this log. A compliance feature that blocked
respondents, showed them a blank screen, and stored no record of what they
agreed to.
**Found:** by an adversarial pass over items the backlog audit had called
*done*. The first auditor read the model, the migration, the player and 231
lines of green tests and concluded the feature shipped. It had not.

`consent_gate` joined `Survey::PAGED_TYPES` on the server. The editor's
`serialize()` still said:

```js
const primPages = type === "scenario" ? … : []
```

`serialize()` rebuilds every card from live DOM on **every** save and PATCHes
the whole deck, so a consent gate always arrived with no `pages`, and the
sanitiser's `Array(nil)` rewrote them to `[]`. Confirmed by running the exact
payload the editor emits through the sanitiser:

```
pages after a round-trip   : []
consent_gate_card?         : true
consent_gated?             : true
consent_snapshot_text      : nil
```

The gate goes on blocking respondents — with nothing on the screen — and
`Response#consent_text_snapshot` records nothing. Because autosave fires 1.5s
after *any* edit, editing an unrelated card destroyed the consent copy.
Translated pages died with it, on the same gate.

A second omission sat next to it: the type panel's `COMPONENTS` table had no
`consent_gate` entry, and the lookup falls back to `() => ""`, so picking
"Consent screens" blanked the card. `welcome_card` is listed explicitly as
`() => ""`, which is what shows the empty fallback here was an oversight rather
than a decision.

**Why every test passed:** `consent_gate_card_test.rb` calls the sanitiser with
pages already supplied and renders from cards seeded via `create!`. Its only
PATCH test asserts `:locked`. No test made a round trip through the editor, and
there is no JS test runner, so nothing in the suite could see `serialize()`.

**Fix:** `app/javascript/lib/paged_types.js` mirrors `Survey::PAGED_TYPES`, and
the four places that hardcoded `"scenario"` now ask `isPaged(type)`. Added the
missing `consent_gate` component builder.

**Guards:** `test/system/consent_gate_editor_test.rb` drives a real editor
round trip — three of its four tests fail against the unfixed build, including
the snapshot one. `test/lib/js_constant_parity_test.rb` asserts the JS and Ruby
lists agree, that every paged type has a component builder, and that neither
file gates on the literal `"scenario"` again. It checks `ROUTABLE_TYPES` against
`LogicGraph::ROUTABLE` too — same mirroring, same latent drift.

**Lesson:** two constants kept in step by a comment that says "keep in
lock-step" are not kept in step. And a feature is not shipped because its model
and its player agree — the editor has to be able to author it.

---

## BUG-014 — An undo stack that undid the wrong action

**Severity:** ⌘Z silently reverted an edit the creator had finished with, while
leaving the one they meant to undo in place.
**Found:** auditing the backlog against the code rather than against the plan.

`recordCardDeletion` and the reorder handlers pushed inverse operations. Adding
a card pushed **nothing** — so the stack was asymmetric, and the next ⌘Z popped
whatever delete or reorder happened *before* the add.

The test makes the shape unmistakable. Delete card 2, add a new card, press ⌘Z.
Expected three cards; the unfixed build gives **five** — the deleted card is
back and the added one is still there. Two wrong outcomes from one keystroke.

**Fix:** `recordCardInsertion` as the mirror of `recordCardDeletion`, wired into
all four insertion gestures (add-question modal, duplicate, add-card-to-flow,
and the flow-panel starter card). Flow creation gets `recordFlowCreation`
instead: that gesture mints a flow *and* several cards, so a per-card inverse
would let ⌘Z strand a flow holding fewer cards than it was built with. One
gesture, one undo entry.

**Guard:** `test/system/editor_undo_test.rb`, five tests, verified against a
build with `recordCardInsertion` disabled — which is how the five-card result
above was produced.

**Also found while writing it:** the "Add consent gate" CTA wears the same
`aq-insert-btn` class as the per-card "Add question" CTA and sits earlier in the
DOM, so the obvious selector adds a consent gate instead. Not a user-facing bug
— they have distinct `data-action`s and sit in different places on screen — but
worth knowing before writing another editor test.

**Lesson:** an incomplete undo stack is not a partial feature, it is a wrong
one. Every operation that mutates the structure has to push, or the stack
silently misattributes the next keystroke.

---

## BUG-013 — A blank rename erased a Verto's name, past a guard written to stop it

**Severity:** a stray select-all-delete in the editor wiped the Verto's name,
and the autosave persisted it 1.5 s later with no confirmation.
**Found:** P2-5, on the first run of the editor browser suite.

The editor had a guard for exactly this. On `blur`:

```js
restoreRenameIfBlank() {
  if (el.textContent.trim()) return
  el.textContent = this.titleValue      // ← already blank by now
}
```

The `input` handler fires first and does `this.titleValue = next` with `next`
being the empty string, so the blur guard restored the blank **over the blank**.
It read the one value the bug had already destroyed. The server took whatever
it was sent — `attrs[:title] = payload["title"] if payload.key?("title")` — so
nothing else stood in the way.

**Fix:** `renameVerto` now bails on a blank instead of storing it, which both
keeps blanks out of the payload and leaves the blur guard something real to
restore. The server independently drops a blank title, and strips the one it
does keep.

**Guard:** the browser test that found it, plus two integration tests over the
server half — one asserting three flavours of blank are ignored, one asserting a
padded-but-real name still renames, so the fix can't over-correct into refusing
legitimate titles. Both were verified to fail against the unfixed controller.

**Lesson:** the same shape as BUG-008 and BUG-003 — a guard that reads state the
bug has already corrupted is not a guard. No unit test would have caught it
either: the defect lives in the *ordering* of two DOM event handlers, which is
only observable in a browser. It sat in code that shipped with a comment
explaining the protection it wasn't providing.

---

## BUG-012 — A key added after the translation payload was dispatched

**Severity:** three locales would have rendered a raw dot path.
**Found:** P2-2, by a parity check over the locales that had landed.

Fixing BUG-011 created `flash.surveys.image_unverified` — a key that did not
exist when the six translator agents received their payload. Three of them
(de, it, nl) therefore had no translation for it; three others picked it up
only because they had been told to read `en.yml` first to match its style,
which was luck rather than design.

**Fix:** backfilled by hand into every locale, with a guard in the backfill
script that refuses to touch a file whose `flash` section has not been written
yet, so it can be re-run safely as the remaining locales land.

**Lesson:** a fan-out's input is frozen at dispatch. Any key added after that
point is invisible to it, and the only thing that catches the gap is a parity
check run afterwards over the union of what exists — not over what was sent.

---

## BUG-011 — A class-body constant can't hold a translation, and dev never notices

**Severity:** would have failed the production deploy at boot.
**Found:** P2-2, by force-loading the controller after a scripted edit.
**Fixed in:** `b7a5f03`

The extraction that moved controller flash copy into i18n keys rewrote two
class-body constants:

```ruby
EDITING_LOCKED_MESSAGE = t("flash.surveys.editing_locked")
```

`t` is not defined in a class body. `bin/rails runner 'puts "boot ok"'` printed
**boot ok**, because development does not eager-load controllers, so the constant
was never evaluated. `Rails.application.eager_load!` — what production actually
does at startup — raised `NoMethodError: undefined method 't' for class
SurveysController`. The app would not have started.

A second bug was hiding behind the first: even if `t` had resolved, a constant is
evaluated **once at boot**, pinning every creator to whichever locale happened to
be active then. That is the exact behaviour the change existed to remove.

**Fix:** all three message constants became methods
(`editing_locked_message`, `settings_locked_message`,
`could_not_verify_image_message`). The third was still hardcoded English and
gained a key of its own.

**Guard:** `Rails.application.eager_load!` is now run as an explicit gate
alongside the usual four before pushing. `bin/rails runner` is not evidence that
the app boots.

---

## BUG-010 — Stashing files that concurrently running agents are writing

**Severity:** produced a pushed commit whose message misdescribes its contents.
**Found:** P2-2, by reading `git show --stat` after the push.

To commit the English extraction cleanly I ran `git stash push` on three locale
files, committed, then popped. Background translator agents wrote to those same
files during that window, so `git add -A` swept up four locales (fr, de, it, nl)
that the commit message says are not there.

The code is correct; the description is not. History was not rewritten — the
follow-up commit corrects the record instead.

**Fix / lesson:** do not use the working tree as scratch space while background
agents hold it. Either wait for them, or have the agents return data instead of
writing files. The rest of that workflow did the latter deliberately, and only
the translation phase — chosen for file-disjointness — wrote directly.

---

## BUG-009 — A browser test that passed with the feature disabled

**Severity:** the test proved nothing it claimed to.
**Found:** P2-5, by deliberately breaking the feature and re-running.
**Fixed in:** `d87b2a8`

The first system tests for keyboard selection passed with
`picker#pickOnKey` removed. Cuprite's `Element#send_keys` **clicks** the element
to focus it first, so the click handler did the work and "selected with the
keyboard alone" was asserting nothing.

**Fix:** focus through the DOM (`element.focus()`), then deliver the key with the
CDP keyboard, so no pointer is involved. Disabling the handlers now fails all
three tests.

**Guard:** every test in that file was re-checked against a deliberately broken
build before being trusted.

---

## BUG-008 — A "is this controller rate limited?" matcher that returned true for everything

**Severity:** a security guard that guarded nothing.
**Found:** P1-12, by running the matcher against controllers known to have no limit.
**Fixed in:** `4e7f20b`

The first matcher looked for any `before_action` lambda originating in
`action_controller`, and so reported **true for every controller inheriting
`ApplicationController`** — including `LegalController` and
`OrganisationsController`, which have no rate limits at all.

**Fix:** match only lambdas defined in
`action_controller/metal/rate_limiting.rb`.

**Guard:** a test asserts the matcher still reports **zero** for those two
controllers, so it cannot rot back into a tautology.

---

## BUG-007 — Two unauthenticated password oracles

**Severity:** brute-force against any account, unthrottled.
**Found:** P1-12, by auditing every call site of `User.authenticate_by` rather
than only the ones the plan named.
**Fixed in:** `4e7f20b`

`InvitesController#accept` and `FunderInviteAcceptancesController#accept` both
verify a password using an email taken from the **form**, not the invite, and
neither had any rate limit. Anyone holding an invite link could test passwords
against any address in the system.

**Fix:** both bounded per IP. Per-address was deliberately not used there — the
action multiplexes several flows, and keying on a blank address would throttle
legitimate signed-in joins.

---

## BUG-006 — A time-window test that flaked

**Severity:** a flaky test is worse than no test.
**Found:** P1-11, by a single failure in one full-suite run that two later runs
did not reproduce.
**Fixed in:** `76568f1`

`SharedRateLimiter` keys its budget on `Time.now.to_i`. Calls straddling a
second boundary got a fresh window, so "the next call must be refused" failed
intermittently.

**Fix:** the budget tests freeze the clock with `travel_to`. What is under test
is the counting, not the wall clock.

---

## BUG-005 — A foreign key that would have broken organisation deletion

**Severity:** would have started raising on a normal user action.
**Found:** P1-9, by asking what the new constraint makes *fail* rather than only
what it prevents.
**Fixed in:** `c272974`

`CommonQuestionSet` had no `has_many :partnership_common_question_sets`, so
deleting a set left its share rows behind. Harmless while the column was
unconstrained; with a foreign key it becomes an aborted destroy — and
`Organisation` destroys its sets, while a set can be shared with a partnership in
a **different** organisation whose cascade never touches those rows.

**Fix:** added the missing association with `dependent: :destroy`, in the same
commit as the constraint.

**Guard:** two cascade tests, both verified to fail without the association.

---

## BUG-004 — A JS-facing string outside the `js:` namespace renders as a raw key

**Severity:** respondents saw `player.tokens_earned` on screen.
**Found:** in the browser. No test could see it.
**Fixed in:** the token-reveal work.

`layouts/_i18n_js.html.erb` exposes only the `js:` namespace as `window.I18N`.
A key added under `player:` instead of `js.player:` resolves server-side and
fails in the browser.

**Guard:** new browser-facing strings are checked against the actual
`window.I18N` payload, not just `I18n.t`.

---

## BUG-003 — `attachment.try(:named_variants)` is permanently false

**Severity:** silently defeated the whole change it was guarding.
**Found:** reading the Active Storage source rather than trusting `try`.

`named_variants` is **private**, so `try` returns nil and the guard never fired.
The thumbnail preprocessing looked correct and did nothing.

**Fix:** read the reflection from the record's public
`attachment_reflections` instead.

---

## BUG-002 — `remove_method` on a real `def self.call`

**Severity:** broke ten unrelated tests.
**Found:** twice — the second time recognising it as the same mistake.

Stubbing a class method with `define_singleton_method` and then
`remove_method` deletes the *original* definition, not the stub.

**Fix:** use the repo's own `stub_method` helper in `test/test_helper.rb`, which
restores the original.

---

## BUG-001 — `rack-timeout`'s `wait_timeout` silently clamps the service timeout

**Severity:** would have quietly reduced a deliberate 240s bound.
**Found:** reading the gem's source instead of its README.
**Fixed in:** `0dfddc4`

`Rack::Timeout` reduces `service_timeout` based on `wait_timeout` unless
`service_past_wait` is set. The generous tier for AI endpoints would not have
been generous.

**Fix:** `wait_timeout: false` on every instance.

---

## The recurring shape

Nine of these (001, 003, 008, 009, 011, 013, 014, 015, and BUG-004's whole
class) share one pattern: **the check that was available said everything was
fine.** `bin/rails runner` booted. `try` returned nil without error. The matcher
returned true. The browser test went green. The blur guard restored the title.
231 lines of consent tests passed. In each case the only thing that found the
bug was deliberately trying to make it fail — force the eager load, break the
feature and re-run the test, run the matcher against a known-negative.

Green is evidence only when you know what red looks like.

## The second shape: a boundary nobody tests

013, 014 and 015 add one of their own. Each lived exactly where two halves of
the system meet and each half looked correct on its own:

* an input handler and a blur handler, correct apart, wrong in sequence;
* a stack that pushed on delete and not on insert;
* a Ruby constant and its JS mirror, agreeing everywhere except the one type
  that had just been added.

No unit test can see any of them, because no unit owns the boundary. Two of the
three were found only once a browser could drive the editor, and the third only
because a second reader was asked to *refute* the first one's "done" rather than
confirm it. Both are worth keeping: the harness, and the habit of not accepting
a verdict from whoever produced the work.
