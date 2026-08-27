// One tap-card statement's media layer, as inline style — the client-side twin
// of ApplicationHelper#option_media_style. Three places paint this layer
// (type_panel's tap_card rebuild, card_editor#addTapOption, and the media
// picker when a picture is applied), and before this module each wrote its own
// string; they had already drifted once over `center/cover`.
//
// The url goes on as LONGHANDS, never the `background` shorthand: a shorthand
// resets background-position with it, and an inline declaration outranks the
// stylesheet — so the shorthand silently undid every reposition. See
// .rotate-card-media.

// Same positional gradients as ApplicationHelper::OPTION_TILE_FILLS and the
// media picker's TAP_OPTION_FILLS: the fallback a statement with no picture
// renders, keyed on its index so the deck reads as a set.
export const OPTION_TILE_FILLS = [
  [ "#d4edda", "#a8d5b5" ], [ "#d1ecf1", "#9fd5df" ], [ "#fff3cd", "#ffd88a" ],
  [ "#f8d7da", "#f5a8b0" ], [ "#e2d9f3", "#c3aee8" ]
]

export const FOCAL_ZOOM_MAX = 3

// Centre for anything that isn't a number — never 0, which would silently pin
// the frame to an edge. Mirrors Survey.sanitize_focal_percent.
export function focalPercent(value) {
  const n = Number(value)
  return Number.isFinite(n) ? Math.round(Math.min(100, Math.max(0, n))) : 50
}

// Cover-fit for anything that isn't a number. Mirrors Survey.sanitize_focal_zoom.
export function focalZoom(value) {
  const n = Number(value)
  return Number.isFinite(n) ? Math.min(FOCAL_ZOOM_MAX, Math.max(1, n)) : 1
}

// The reposition as the custom properties the CSS reads. Both forms of each
// axis, because CSS cannot turn the percentage into the bare fraction: the
// percentage drives background-position, the fraction drives the layer's own
// offset (see .split-left-img).
export function focalProperties(x, y, z) {
  const fx = focalPercent(x)
  const fy = focalPercent(y)
  return {
    "--focal-x": `${fx}%`,
    "--focal-y": `${fy}%`,
    "--focal-fx": String(Math.round(fx) / 100),
    "--focal-fy": String(Math.round(fy) / 100),
    "--focal-zoom": String(Number(focalZoom(z).toFixed(2)))
  }
}

export function focalPropertiesCss(x, y, z) {
  return Object.entries(focalProperties(x, y, z)).map(([ k, v ]) => `${k}:${v}`).join(";")
}

// Write the pair onto a live element, replacing whatever was there. Used by the
// picker as the creator drags and when a new picture lands on a slot.
export function applyFocal(el, x, y, z) {
  if (!el) return
  for (const [ prop, value ] of Object.entries(focalProperties(x, y, z))) {
    el.style.setProperty(prop, value)
  }
}

// The whole inline style for the layer. `focal` is one entry of the card's
// option_focals ({x, y, z}) or null for a slot that has never been reframed.
export function optionMediaStyle(image, focal, index) {
  if (!image) {
    const [ a, b ] = OPTION_TILE_FILLS[index % OPTION_TILE_FILLS.length]
    return `background-image:linear-gradient(135deg,${a},${b});`
  }
  const f = focal || {}
  return `background-color:#fff;background-image:url('${String(image).replace(/'/g, "\\'")}');` +
         focalPropertiesCss(f.x, f.y, f.z)
}
