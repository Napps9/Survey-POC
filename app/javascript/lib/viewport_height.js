// Mobile browsers — including several in-app browsers such as Slack's — can
// be inconsistent about the CSS `dvh` unit, sometimes locking a fixed-height
// overlay to the wrong toolbar state on first paint. That leaves elements
// pinned to the bottom of the box (like the player's footer/Next button)
// below the actually-visible viewport, with no scroll to reach them. Track
// the real measured height instead so CSS can fall back to it.
//
// --app-100vh is the TOOLBAR measurement. It is not, and must never become,
// the keyboard measurement.
//
// .preview-overlay is `position: fixed; inset: 0` PLUS `height:
// var(--app-100vh)`. That is over-constrained, so `bottom` is dropped and
// `height` wins: the box is anchored to the top of the LAYOUT viewport and
// sized to the VISUAL one. While those two agree — every case this file was
// originally written for — that is harmless. When a soft keyboard opens they
// stop agreeing: visualViewport.height shrinks, the overlay shrinks upward
// from layout-y 0, and the browser scrolls the visual viewport down to reveal
// the focused field. What the respondent sees below the overlay is then bare
// <body> (#272D4A) — the "huge gap" — with the footer stranded in the middle
// of it.
//
// So: publish the toolbar's height, and STOP publishing while a keyboard is
// up. Frozen, the overlay stays exactly the layout viewport; the keyboard
// covers its lower part, the browser scrolls only as far as it must (never
// past the keyboard's own height, so no bare body can appear), and the card
// does not reflow at all while someone is typing into it.
//
// The threshold is a DELTA, not a platform sniff, because the two platforms
// disagree about which viewport moves and that disagreement is the signal:
//   - iOS Safari (and Chrome without interactive-widget=resizes-content):
//     innerHeight holds, visualViewport.height drops → large delta → freeze.
//   - Chrome WITH interactive-widget=resizes-content (the player sets it —
//     see layouts/_head): both shrink together → delta ~0 → keep publishing,
//     which is correct there, because the layout viewport really is the
//     visible area and `inset: 0` is already right.
// 120px sits comfortably above any browser toolbar (the tallest measured is
// ~90px) and comfortably below any soft keyboard (the shortest is ~250px).
const KEYBOARD_DELTA = 120
const TEXTY = /^(?:text|search|email|tel|url|number|password)$/

const isTextControl = (el) =>
  !!el && (el.tagName === "TEXTAREA" || el.isContentEditable ||
           (el.tagName === "INPUT" && TEXTY.test(el.type || "text")))

const setAppViewportHeight = () => {
  const vv = window.visualViewport
  if (!vv) {
    document.documentElement.style.setProperty("--app-100vh", `${window.innerHeight}px`)
    return
  }
  const hidden = window.innerHeight - vv.height
  if (hidden > KEYBOARD_DELTA && isTextControl(document.activeElement)) return
  document.documentElement.style.setProperty("--app-100vh", `${vv.height}px`)
}

// Both edges of the keyboard. On close the visualViewport resize can fire
// while activeElement is still the field (the ordering is not guaranteed), so
// re-measure a frame after focusout too — otherwise a stale frozen height
// outlives the keyboard that justified it.
const schedule = () => requestAnimationFrame(setAppViewportHeight)

setAppViewportHeight()
window.addEventListener("resize", setAppViewportHeight)
// Rotating with the keyboard up would otherwise stay frozen at the previous
// orientation's height: drop focus first, then measure.
window.addEventListener("orientationchange", () => {
  if (isTextControl(document.activeElement)) document.activeElement.blur()
  schedule()
})
document.addEventListener("focusin", schedule, true)
document.addEventListener("focusout", schedule, true)
if (window.visualViewport) {
  window.visualViewport.addEventListener("resize", setAppViewportHeight)
}

// ── Pinning the player overlay to the VISUAL viewport ─────────────────────
//
// Everything above measures the toolbar and publishes a height for CSS to use.
// That was never quite enough, and a device pass showed why: on an iPhone with
// the "+ Other" box open, the card sat with its top off screen, the footer
// stranded mid-screen, and a band of bare <body> navy between the card and the
// keyboard — the exact shape the comment at the top of this file describes.
//
// The root cause is the one that comment names: `.preview-overlay` is
// `position: fixed; inset: 0` PLUS a height. Over-constrained, `bottom` is
// dropped, so the box is ANCHORED to the layout viewport and SIZED to the
// visual one. A height alone cannot fix that — get the size right and the box
// is still in the wrong place the moment the two viewports disagree.
//
// The delta test above infers which platform it is on and freezes. That is an
// inference about browser behaviour, and browser behaviour moves: the whole
// design rests on "iOS Safari ignores interactive-widget entirely", which was
// true when it was written. So stop inferring. Measure the visible rectangle
// and put the overlay exactly on it:
//
//   height    = visualViewport.height     → the right size
//   translateY(visualViewport.offsetTop)  → the right place
//
// This is correct without needing to know which platform, or which way this
// year's Safari jumped:
//   - keyboard shrinks the visual viewport only (classic iOS): height tracks
//     it, the translate cancels the reveal-scroll. No bare body, ever.
//   - keyboard shrinks the layout viewport too (Chrome with
//     interactive-widget, and any Safari that starts honouring it): the two
//     viewports agree, offsetTop is 0, and this is a no-op that sets the
//     height it already had.
//
// --app-100vh is deliberately left alone. It still measures the toolbar for
// its other consumers (.regions-overlay, and a max-height further down), and
// the freeze above still protects them.
//
// One transform caveat, checked rather than assumed: a transform makes the
// overlay a containing block for `position: fixed` DESCENDANTS. The player has
// exactly one — .regions-overlay, the Compare panel — and it is `inset: 0`, so
// positioning it against an overlay that exactly covers the visible area puts
// it precisely where a fullscreen panel belongs. The transform is also only
// set while there IS a scroll to cancel, so in the ordinary case no containing
// block is created at all.
const pinOverlay = () => {
  const el = document.querySelector(".preview-overlay")
  const vv = window.visualViewport
  if (!el || !vv) return
  el.style.height = `${vv.height}px`
  el.style.transform = vv.offsetTop ? `translateY(${vv.offsetTop}px)` : ""
}

// ── ?vpdebug=1 ────────────────────────────────────────────────────────────
// The numbers behind all of the above, on the device, because this is the one
// path that cannot be exercised in a headless browser: the delta the freeze
// keys off, whether the freeze is engaged, and where the overlay actually
// ended up. Pinned to the visual viewport itself so it stays on screen with a
// keyboard up.
const vpDebug = () => {
  if (!/[?&]vpdebug=1/.test(window.location.search)) return null
  const box = document.createElement("div")
  box.style.cssText = "position:fixed;top:0;left:0;right:0;z-index:2147483647;" +
    "background:rgba(0,0,0,0.82);color:#0f0;font:11px/1.45 ui-monospace,Menlo,monospace;" +
    "padding:6px 8px;white-space:pre;pointer-events:none"
  document.body.appendChild(box)
  return () => {
    const vv = window.visualViewport
    const el = document.querySelector(".preview-overlay")
    const r  = el && el.getBoundingClientRect()
    const a  = document.activeElement
    box.style.transform = vv && vv.offsetTop ? `translateY(${vv.offsetTop}px)` : ""
    box.textContent = [
      `innerH ${window.innerHeight}  vv.h ${vv ? Math.round(vv.height) : "-"}  ` +
        `delta ${vv ? Math.round(window.innerHeight - vv.height) : "-"}  (freeze >${KEYBOARD_DELTA})`,
      `vv.offsetTop ${vv ? Math.round(vv.offsetTop) : "-"}  vv.pageTop ${vv ? Math.round(vv.pageTop) : "-"}`,
      `--app-100vh ${getComputedStyle(document.documentElement).getPropertyValue("--app-100vh").trim() || "(unset)"}`,
      `kbd-open ${document.documentElement.classList.contains("kbd-open")}  focus ${a ? a.tagName.toLowerCase() : "-"}`,
      `overlay top ${r ? Math.round(r.top) : "-"} h ${r ? Math.round(r.height) : "-"} bottom ${r ? Math.round(r.bottom) : "-"}`
    ].join("\n")
  }
}

const drawDebug = vpDebug()
const syncViewport = () => { pinOverlay(); if (drawDebug) drawDebug() }

// The keyboard MOVES, and these events do not describe the movement — they
// report where it got to. iOS animates the keyboard in over ~250ms and fires
// visualViewport `resize` only a handful of times across it, in practice often
// once, at the end. Pinning on those events alone therefore holds the
// pre-keyboard geometry for the whole animation and then corrects it in one
// step: right answer, arrived at visibly. That step is the "flashed into
// place".
//
// So for a short window after anything that can move the viewport, re-pin
// every frame. The overlay then rides the keyboard up instead of catching up
// with it.
//
// Deliberately a DEADLINE rather than a nested loop: pinning changes layout,
// layout can fire more resize events, and a loop that started a second loop
// each time would multiply per event and never wind down. `settle()` only ever
// pushes the finish line back; at most one rAF chain exists at a time, and it
// ends on a wall clock whatever else happens. 700ms covers the slowest
// keyboard transition measured with room to spare, and outside these windows
// nothing runs at all.
const SETTLE_MS = 700
let settleUntil = 0
let settleFrame = null

const step = () => {
  syncViewport()
  if (Date.now() < settleUntil) {
    settleFrame = requestAnimationFrame(step)
  } else {
    settleFrame = null
  }
}

const settle = () => {
  // This module is imported by application.js, so it loads on every page — but
  // there is only something to track on a page carrying a player overlay.
  // Without this guard, every focusin in the EDITOR (a creator clicking into
  // any card's contenteditable, which is most of what editing is) would arm a
  // 700ms 60fps chain of calls that early-return, all day, on a laptop that is
  // also rendering the designer.
  if (!document.querySelector(".preview-overlay")) return
  settleUntil = Date.now() + SETTLE_MS
  if (settleFrame === null) settleFrame = requestAnimationFrame(step)
}

syncViewport()
window.addEventListener("resize", settle)
window.addEventListener("orientationchange", settle)
document.addEventListener("focusin", settle, true)
document.addEventListener("focusout", settle, true)
if (window.visualViewport) {
  // scroll as well as resize: offsetTop changes when the browser scrolls the
  // visual viewport to reveal a field, and that scroll is the half of this
  // that a height-only fix could never see.
  window.visualViewport.addEventListener("resize", settle)
  window.visualViewport.addEventListener("scroll", syncViewport)
}
