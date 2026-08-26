# VertoNow one-pager → Webflow

A rebuild kit for putting the research one-pager on the marketing site as a real
page, rather than iframing the emailable file into it.

Generated from `public/verto-for-research.html` by `build_webflow.py`, here in
this folder. Regenerate rather than hand-editing the generated files — the next
run overwrites them. It reads the shipped one-pager and strips it; it does not
regenerate that, which `build_research.py` does.

## What's here

| File | What it's for |
|---|---|
| `index.html` | Reference build of the finished page. Open it in a browser — this is the target. Not for uploading anywhere. |
| `styles.css` | The stylesheet behind it, for reading values off while building in Webflow. |
| `assets/` | Every image as a real file. Upload these to Webflow. |
| `webflow-1-head-css.html` | Paste 1 of 3 — Page settings → Custom code → **Inside `<head>` tag** |
| `webflow-2-embed-markup.html` | Paste 2 of 3 — an **HTML Embed** element on the canvas |
| `webflow-3-body-js.html` | Paste 3 of 3 — Page settings → Custom code → **Before `</body>` tag** |

The one-pager is 583 KB because it has to survive being emailed: fonts, images
and an offline fallback deck are all base64'd into it. Hosted, none of that
earns its place — this is 38 KB of source and 319 KB of images a CDN caches.

## Why the demo is split across three fields

Webflow caps an HTML Embed element at **10,000 characters**. The device mockup —
the laptop and phone with the live Verto in them — is about 15,500. It splits
along seams Webflow already provides, and each piece lands well inside the
limit:

```
webflow-1-head-css.html      6,237 chars   the mockup's CSS
webflow-2-embed-markup.html  1,649 chars   the markup, on the canvas
webflow-3-body-js.html       7,887 chars   the sizing + hand-off script
```

The script has to run after the markup exists. Putting it in **Before `</body>`**
guarantees that without a `DOMContentLoaded` wrapper.

## Order of work

1. **Fonts.** Overpass (400–700) and Poppins (600, 700), both on Google Fonts —
   Site settings → Fonts → Google Fonts. The one-pager embedded them only
   because an emailed file has no network to fetch from.
2. **Upload `assets/`** to Webflow. Note the folder URL Webflow serves them
   from; you'll paste it over `ASSET_BASE` in part 2.
3. **Build the four sections** natively — hero, benefits, `01`–`04`. Read the
   values off `styles.css`; nothing in them is exotic.
4. **Drop an HTML Embed** where the mockup goes in section `01`, and do the
   three pastes above.
5. **Add your domain to the player's `frame-ancestors`** — see below. Without
   it the laptop and phone show a static screenshot and a link, not a Verto.

## The bit that isn't Webflow: `frame-ancestors`

The player refuses to be framed by other websites on purpose
(`app/controllers/player_controller.rb`) — `'self'` and `file:` only, so no
site can embed someone's Verto without being named. Your Webflow domain has to
be named, and **so does the `.webflow.io` staging domain**, or the embed stays
broken for the whole build.

It reads from an env var, space- or comma-separated, no code change needed:

```
PLAYER_FRAME_ANCESTORS="https://www.playverto.com https://playverto.com https://your-site.webflow.io"
```

Scheme-qualified origins only — a bare host is silently inert in a CSP source
list, and `*` is dropped rather than handing every site on the internet the
ability to frame a Verto. Unset, the player behaves exactly as before.

Note `frame-ancestors` is checked against **every** ancestor, not just the
immediate parent — so this is required whether you embed the player directly or
nest it inside something else.

## What changed from the emailed version

The one-pager is a proposal addressed to one firm. A public page can't be, so
the generator rewrites:

- **Topbar, side nav and footer removed** — your Webflow site draws its own, and
  shipping ours too would put two of each on the screen. Their CSS is stripped
  with them.
- **"Prepared for Strategic Analytics"** — gone, along with the eyebrow naming
  them and the `<span class="firm">` in section 04.
- **The hero's sector pills** were *their* coverage sectors. Removed.
- **"Your 100–150 primary interviews"** → "Your primary interviews".
- **Section 04** "The Proposal" → "Getting Started"; the mailto to Michael is
  now `#contact`, for your Webflow form — a named person's inbox on a page that
  crawlers read is a spam magnet.
- **The offline fallback deck is gone** — 3 images and its CSS. A hosted page is
  already online; if the player is unreachable the screenshot and the
  "Open in a new tab" link say the same thing for none of the weight.
- **`.shell` is one column, 880px, centred.** It was a two-column grid with the
  side nav on the left; with the nav gone, `main` would otherwise render inside
  the nav's 240px column — which is exactly what the first build did.

## Still yours to decide

- **The demo Verto** is `/play/s3-wPFWIgpIVpATc2IAzPsBq` — a live link, so
  anyone playing it on a public page lands in your real results and meets the
  consent gate. A Test Mode `/test/:token` link records nothing and skips the
  banner; if you want that here, it's one string in part 3.
- **Light theme only.** The emailed version had a dark/light toggle; a marketing
  page usually commits to one. The dark palette is still in `styles.css` under
  `[data-theme]` if you want it back.
- **The `#contact` CTA** needs pointing at your real form.
