// THE VISIBLE BAND — the strip of the layout viewport a respondent can
// actually see once a soft keyboard is up.
//
// This exists because two measurements that look interchangeable are not, and
// mixing them up is invisible on the platform most of this gets tested on.
//
//   getBoundingClientRect() returns LAYOUT-viewport coordinates.
//   visualViewport.height is a LENGTH, not a coordinate.
//
// The band occupies [offsetTop, offsetTop + height] in layout space. So
// `height` alone is only the band's lower edge when offsetTop is zero:
//
//   Android, with interactive-widget=resizes-content, shrinks the LAYOUT
//   viewport to the band and leaves offsetTop at 0. The two spaces coincide
//   and comparing a client rect against bare `height` is accidentally right.
//
//   iOS Safari does not shrink the layout viewport. It SCROLLS the visual
//   viewport, so offsetTop goes positive — and lib/viewport_height.js then
//   pins the player overlay with translateY(offsetTop), which pushes every
//   descendant's client rect down by that same amount. The offset therefore
//   lands on both sides of any comparison and cancels on neither.
//
// Measured against a stubbed 200px split: omitting the term put the floor at
// 508 instead of 611, so a field already in view was judged 184px too low
// rather than 81 — a hundred pixels of smooth scroll nobody asked for, a third
// of a second after the card had already settled.
//
// Arguments are injectable so this can be exercised without a real keyboard,
// which no headless browser has.
export function visibleBandEnd(vv = window.visualViewport, fallback = window.innerHeight) {
  if (!vv) return fallback
  return vv.offsetTop + vv.height
}

// The band's upper edge, for completeness and for anything measuring downward.
export function visibleBandTop(vv = window.visualViewport) {
  return vv ? vv.offsetTop : 0
}
