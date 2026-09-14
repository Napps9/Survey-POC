// Which ink a card's mobile background can carry: white on a dark backdrop,
// near-black on a light one. "The text colour goes white regardless of the
// background — we need it to react to the colour of the background."
//
// Decided ONCE, when the creator picks, and stored on the card as
// media_bg.ink. Not at render time, and that is the whole design: a respondent's
// phone would have to decode the picture before it could colour the question,
// which is a flash of the wrong ink on every card that carries one, on the
// slowest connections, forever. The editor has the picture in front of it
// already.
//
// Ruby's twin is Survey.backdrop_ink_for (it sanitises what this sends and is
// what an import or a seed goes through); backdrop_ink_parity_test holds the
// two to the same threshold and the same worked examples.

// WCAG relative luminance. The same curve BrandPalette uses, because "is this
// light" has one answer in this app, not one per file.
export function relativeLuminance(r, g, b) {
  const chan = (v) => {
    const s = v / 255
    return s <= 0.04045 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4)
  }
  return 0.2126 * chan(r) + 0.7152 * chan(g) + 0.0722 * chan(b)
}

// 0.38, not 0.5. The question is not "which half is this nearer" but "which ink
// clears 4.5:1 against it", and the two inks are not symmetrical: white
// (L = 1) clears 4.5:1 up to L = 0.183, and #1C2034 (L = 0.0166) clears it down
// to L = 0.25. Between those two every backdrop fails one ink or the other, so
// the line goes where the failures are least bad — a shade above the midpoint
// of the two limits, because a dark ink on a mid backdrop reads better than a
// light one, the ink carrying its own shadow either way.
export const LIGHT_BACKDROP_THRESHOLD = 0.38

export function inkForLuminance(luminance) {
  return luminance >= LIGHT_BACKDROP_THRESHOLD ? "dark" : "light"
}

// "#2e3564" → "light". Null for anything that isn't a hex colour.
export function inkForColor(hex) {
  const m = /^#?([0-9a-f]{6})$/i.exec(String(hex || "").trim())
  if (!m) return null
  const n = parseInt(m[1], 16)
  return inkForLuminance(relativeLuminance((n >> 16) & 255, (n >> 8) & 255, n & 255))
}

// The picture's own average, measured off a 32x32 draw — small enough to be
// free and large enough that one bright corner does not decide a dark photo.
//
// Resolves to null rather than guessing when the pixels cannot be read: a
// cross-origin image without CORS headers taints the canvas and getImageData
// throws. Null means "leave the ink alone", which keeps the white default
// rather than flipping a card to black ink on a picture nobody measured.
export function inkForImage(url) {
  return new Promise((resolve) => {
    if (!url) return resolve(null)
    const img = new Image()
    img.crossOrigin = "anonymous"
    img.onload = () => {
      try {
        const size = 32
        const canvas = document.createElement("canvas")
        canvas.width = size
        canvas.height = size
        const ctx = canvas.getContext("2d", { willReadFrequently: true })
        ctx.drawImage(img, 0, 0, size, size)
        const { data } = ctx.getImageData(0, 0, size, size)
        let total = 0
        let counted = 0
        for (let i = 0; i < data.length; i += 4) {
          // A transparent pixel is not part of the picture — a PNG cut-out
          // would otherwise be averaged against whatever the canvas
          // initialises to and read as dark.
          if (data[i + 3] < 8) continue
          total += relativeLuminance(data[i], data[i + 1], data[i + 2])
          counted += 1
        }
        resolve(counted ? inkForLuminance(total / counted) : null)
      } catch (_e) {
        resolve(null)
      }
    }
    img.onerror = () => resolve(null)
    img.src = url
  })
}
