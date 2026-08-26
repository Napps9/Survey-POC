# VertoNow one-pager → Webflow

Two ways to get the research one-pager onto the marketing site. Pick one.

Generated from `public/verto-for-research.html` by `build_webflow.py`, here in
this folder. Regenerate rather than hand-editing the generated files — the next
run overwrites them.

---

## Route A — three pastes, no Designer work (~20 minutes)

The whole page markup is 6,815 characters, which fits in **one** HTML Embed. So
the stylesheet and images are served from this app (`public/` is already served
in production), and Webflow only holds the page.

**You get** the exact page in the mockups, live on your domain, indexed
normally — Webflow renders embed content into the published HTML, so unlike an
iframe, Google reads it.
**You give up** editing it in the Webflow Designer. Copy changes come back
through this repo.

1. **Deploy this branch** so the kit is live. Check it:
   `https://app.playverto.com/webflow/styles.css` should return CSS.
2. **New page** in Webflow. Blank — no hero, no container, nothing.
3. **Page settings → Custom code → Inside `<head>` tag** — paste
   `paste-1-head.html` (290 chars).
4. **Drag one HTML Embed** onto the empty canvas and paste `paste-2-body.html`
   (6,815 chars). That's the whole page.
5. **Page settings → Custom code → Before `</body>` tag** — paste
   `paste-3-footer.html` (7,806 chars).
6. **Publish**, then do the `frame-ancestors` step below or the laptop and
   phone will show a screenshot and a link instead of a live Verto.

Step 5 has to be the `</body>` field, not the head: the script looks for the
markup from step 4, and that placement guarantees it already exists.

## Route B — rebuild it natively (a few hours of Webflow work)

Real Webflow elements your team can edit without touching this repo. Use
`index.html` as the target and read values off `styles.css`.

1. **Fonts** — Overpass (400–700) and Poppins (600, 700), both on Google Fonts,
   Site settings → Fonts. The one-pager embedded them only because an emailed
   file has no network to fetch from.
2. **Upload `assets/`** to Webflow. Note the folder URL it serves them from.
3. **Build the four sections** natively — hero, benefits, `01`–`04`.
4. **The device mockup is the one part Webflow can't draw.** It's 15,500
   characters, over the 10,000 embed cap, so it comes in three:

   | File | Where | Size |
   |---|---|---|
   | `webflow-1-head-css.html` | Page settings → Inside `<head>` tag | 6,175 |
   | `webflow-2-embed-markup.html` | an HTML Embed in section `01` | 1,649 |
   | `webflow-3-body-js.html` | Page settings → Before `</body>` tag | 7,887 |

   Replace `ASSET_BASE` in part 2 with your Webflow asset folder (4 places).
5. **`frame-ancestors`**, below.

---

## Both routes: `frame-ancestors`

The player refuses to be framed by other websites on purpose
(`app/controllers/player_controller.rb`) — `'self'` and `file:` only, so no
site can embed someone's Verto without being named. Your Webflow domain has to
be named, and **so does the `.webflow.io` staging domain**, or the embed stays
broken for the whole build.

Set it on the Render service — space- or comma-separated, no code change:

```
PLAYER_FRAME_ANCESTORS="https://www.playverto.com https://playverto.com https://your-site.webflow.io"
```

Scheme-qualified origins only — a bare host is silently inert in a CSP source
list, and `*` is dropped rather than handing every site on the internet the
ability to frame a Verto. Unset, the player behaves exactly as before.

`frame-ancestors` is checked against **every** ancestor, not just the immediate
parent, so this is required either way.

## What's in here

| File | |
|---|---|
| `index.html` | Reference build. Open it — this is the target. |
| `styles.css` | The stylesheet. Served live for Route A; a reference for Route B. |
| `assets/` | 8 images. Served live for Route A; upload them for Route B. |
| `paste-1/2/3-*.html` | Route A. |
| `webflow-1/2/3-*.html` | Route B — the device mockup only. |

583 KB became 38 KB of source and 319 KB of images. Most of that file was
base64: fonts, and an offline fallback deck that only exists so an emailed copy
shows something with no network. A hosted page is already online — if the
player is unreachable, the screenshot and the "open in a new tab" link say the
same thing for none of the weight.

## What changed from the emailed version

It was a proposal addressed to one firm; a public page can't be. The generator
rewrites:

- **Topbar, side nav and footer removed** — your site draws its own, and
  shipping ours too would put two of each on the screen. Their CSS goes too.
- **"Prepared for Strategic Analytics"** — gone, with the eyebrow naming them
  and the `<span class="firm">` in section 04.
- **The hero's sector pills** were *their* coverage sectors. Removed.
- **"Your 100–150 primary interviews"** → "Your primary interviews".
- **Section 04** "The Proposal" → "Getting Started"; the mailto to Michael is
  now `#contact` for your form — a named inbox on a page crawlers read is a
  spam magnet.
- **Light only.** The one-pager boots dark with a toggle, and its CSS is
  written that way: `:root` is dark, `[data-theme="light"]` overrides. A
  Webflow page's body has no such attribute, so it rendered dark — light is the
  default outright here.
- **`.shell` is one column, 880px, centred.** It was a two-column grid with the
  side nav on the left; with the nav gone, `main` would render inside the nav's
  240px column.

## Still yours to decide

- **The demo Verto** is `/play/s3-wPFWIgpIVpATc2IAzPsBq` — a live link, so
  anyone playing it on a public page lands in your real results and meets the
  consent gate. A Test Mode `/test/:token` link records nothing and skips the
  banner; it's one string in `paste-3-footer.html`.
- **The `#contact` CTA** needs pointing at your real form.
