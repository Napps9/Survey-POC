# Respondent accounts — mockups

Mockups for offering a **respondent** an account at the end of a Verto: give an
email, get a place that remembers the Vertos you played, your answers against
everyone else, a wallet of the tokens you collected, the impact the Verto turned
out to have, and the next one to play. Plus where the creator writes the ask,
and where they write the impact months later.

Nothing here is built. `index.html` is a design deliverable — fourteen artboards
plus a worked example and a spec, with numbered callouts, each keyed to a numbered spec (§1–§10) at the foot of
the same page, so the boards and the technical implications stay in one
document.

It is the sibling of `../responder-share/` and continues its fiction — the same
Haverley Town Council, the same "Car-free High Street", the same street. Read
that deck first if you haven't; this one assumes its share card exists.

## Looking at it

Open `index.html` in a browser, or read `shots/*.png`.

| Board | File |
|---|---|
| Worked example (the copy and the five Vertos every board uses) | `shots/00-worked-example.png` |
| A1 · End screen, mobile — the join block in place | `shots/01-end-screen-mobile.png` |
| A2 · The block's five states | `shots/02-join-block-states.png` |
| A3 · End screen, desktop | `shots/03-end-screen-desktop.png` |
| B · The sign-in email, and what the link opens | `shots/04-sign-in-email.png` |
| C1 · `/you` — Your Vertos, mobile | `shots/05-you-mobile.png` |
| C2 · `/you` — desktop, with the wallet and what's next | `shots/06-you-desktop.png` |
| D · One Verto in the account — your answers, kept | `shots/07-one-verto.png` |
| E · The wallet | `shots/08-wallet.png` |
| F · Impact, in three states | `shots/09-impact.png` |
| G · Follow-ups | `shots/10-follow-ups.png` |
| H · "The next one is out" — and the unsubscribe question | `shots/11-next-one-out-email.png` |
| I · Editor — "Ask them to join" | `shots/12-editor-join-block.png` |
| J · Editor — "Impact & follow-ups" | `shots/13-editor-impact-block.png` |
| K · Dashboard tile | `shots/14-dashboard-tile.png` |
| § · The spec, and what it revises | `shots/15-spec.png` |

Haverley Town Council is fictional; Riverside Youth Trust borrows the name of
the demo seeder's partner org. Every illustration — both crests, four Verto
covers, the wordmark — is hand-drawn SVG, so the page carries no external asset.

## What the deck argues, in three lines

1. **The join is consented, not inferred.** The per-survey HMAC stays exactly as
   it is. The browser hands over the handles it already holds — `session_token`
   for the run just finished, and whatever durable `player_key`s `localStorage`
   has — and the server never compares a digest from one survey with one from
   another. Most past Vertos are therefore *unclaimable*, because a plain Verto
   mints no durable key at all (`player_controller.js:209`), and board A2 says
   so on the screen rather than promising "all your Vertos".
2. **This reverses a decision the repo made on purpose.** `docs/DATA_RETENTION.md`
   refuses a durable cross-Verto identity by name, and four code comments assert
   that identities cannot be joined across Vertos. The spec's table lists every
   comment and document that has to be rewritten in the same change, rather than
   leaving them quietly contradicting the schema.
3. **Two things would ship broken if nobody looked.** The neurodiversity wall
   (`survey.rb:2410`) does not cover a new email capture, and the GDPR export and
   erasure paths do not know about accounts. Both are §9.

## The PDF

`responder-accounts-mockups.pdf` is the shareable version — 17 pages, a page per
board, each sized to the board it carries so no sheet runs half empty. Rebuild
it after editing `index.html`:

```
node make_pdf.mjs      # per-board parts into .pdf-parts/ (gitignored)
python3 merge_pdf.py   # stitches and numbers them
```

`merge_pdf.py` needs `pymupdf` (`pip install pymupdf`). It prints the page
rather than stitching `shots/*.png`, so every word in it stays real vector text
— searchable, selectable, and sharp at any zoom.

Both scripts are copies of the ones in `../responder-share/`, and the two
load-bearing details in the `@media print` block came from there too: the sheet
is **1150px wide, not the 1500px the boards use on screen** (page width sets how
large the type reads), and boards that put three or more frames side by side put
their notes underneath instead of in the 300px rail.

## Re-shooting

```
cd docs/mockups/responder-accounts
node shoot.mjs
```

Playwright comes from the global install and Chromium from `/opt/pw-browsers`
(the same pair `.claude/skills/verify/SKILL.md` uses); override with
`PLAYWRIGHT_DIR` and `CHROMIUM` if yours live elsewhere. The script screenshots
each `<section class="board">` by id and **fails loudly** if a board in its
`BOARDS` list has no matching element, so adding a board means adding one row.

## Conventions

`index.html` is **self-contained** — the two brand fonts are base64-embedded,
every crest, cover and icon is inline SVG, and there are no CDN references, so
it works from `file://` and from any host. It follows the build-stamp convention
of its sibling and of the one-pagers in `public/`:

```html
<!-- responder-accounts mockups · build 2026-09-09-a · … -->
<html lang="en" data-build="2026-09-09-a">
```

Bump that stamp when you change the file, and check it in view-source to be sure
you're looking at the copy you think you are.

It lives under `docs/` rather than `public/` deliberately: `public/` is served in
production, and these are internal design documents.
