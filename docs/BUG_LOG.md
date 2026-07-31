# Bug log

Bugs found and fixed while hardening the platform, kept because several of them
share a shape worth recognising: **the obvious check said the code was fine.**

Each entry records what broke, how it was found, why the usual check missed it,
and what now stops it coming back. Newest first.

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

Six of these (001, 003, 008, 009, 011, and BUG-004's whole class) share one
pattern: **the check that was available said everything was fine.** `bin/rails
runner` booted. `try` returned nil without error. The matcher returned true. The
browser test went green. In each case the only thing that found the bug was
deliberately trying to make it fail — force the eager load, break the feature and
re-run the test, run the matcher against a known-negative.

Green is evidence only when you know what red looks like.
