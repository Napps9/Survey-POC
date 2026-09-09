# Responder share — mockups

Mockups for letting a **respondent** pass a Verto on to friends and family at the
end of the player, change.org style: a narrative headline, a social image, and a
message in the respondent's own voice that unfurls in WhatsApp, Messages and the
feeds.

Nothing here is built. `index.html` is a design deliverable — twelve artboards
with numbered callouts, each keyed to a numbered spec (§1–§10) at the foot of the
same page, so the boards and the technical implications stay in one document.

## Looking at it

Open `index.html` in a browser, or read `shots/*.png`.

| Board | File |
|---|---|
| Worked example (the copy every board uses) | `shots/00-worked-example.png` |
| A1 · End screen, mobile — before tapping Share | `shots/01-mobile-end-screen.png` |
| A2 · In-page share sheet, two states | `shots/02-mobile-share-sheet.png` |
| A3 · iOS system share sheet | `shots/03-mobile-native-sheet.png` |
| B1 · End screen, desktop | `shots/04-desktop-end-screen.png` |
| B2 · Desktop share modal | `shots/05-desktop-share-modal.png` |
| C · The same link as it lands, seven unfurls | `shots/06-unfurls.png` |
| D1 · The share image, 1200×630 | `shots/07-share-image.png` |
| D2 · Crop guides and the other image modes | `shots/08-share-image-crops.png` |
| E · Editor "Share preview" block | `shots/09-editor-share-block.png` |
| F · Dashboard attribution tile | `shots/10-dashboard-tile.png` |
| § · The spec and the platform table | `shots/11-spec.png` |

`shots/07-share-image-1200x630.jpg` is the share image at 1:1, saved at quality
82 — it doubles as the check on WhatsApp's ~300 KB budget for a large preview
(currently ~58 KB).

Haverley Town Council is fictional, and the photograph in the share image is a
hand-drawn SVG stand-in for a Verto's real `background_image`.

## The PDF

`responder-share-mockups.pdf` is the shareable version — 12 pages, one per board,
each page sized to its own board so nothing is orphaned or padded. Rebuild it
after editing `index.html`:

```
node make_pdf.mjs      # per-board parts into .pdf-parts/ (gitignored)
python3 merge_pdf.py   # stitches and numbers them
```

It prints the page rather than stitching `shots/*.png`, so every word in it stays
real vector text — searchable, selectable, and sharp at any zoom.

## Re-shooting

```
cd docs/mockups/responder-share
node shoot.mjs
```

Playwright comes from the global install and Chromium from `/opt/pw-browsers`
(the same pair `.claude/skills/verify/SKILL.md` uses); override with
`PLAYWRIGHT_DIR` and `CHROMIUM` if yours live elsewhere. The script screenshots
each `<section class="board">` by id, so adding a board means adding one row to
its `BOARDS` list.

## Conventions

`index.html` is **self-contained** — the two brand fonts are base64-embedded, the
QR and the wordmark are inline SVG, and there are no CDN references, so it works
from `file://` and from any host. It follows the build-stamp convention of the
one-pagers in `public/`:

```html
<!-- responder-share mockups · build 2026-09-09-a · … -->
<html lang="en" data-build="2026-09-09-a">
```

Bump that stamp when you change the file, and check it in view-source to be sure
you're looking at the copy you think you are.

It lives under `docs/` rather than `public/` deliberately: `public/` is served in
production, and these are internal design documents.
