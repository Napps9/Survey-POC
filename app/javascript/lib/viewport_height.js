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
