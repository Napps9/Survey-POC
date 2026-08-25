// Mirror of app/models/concerns/brand_palette.rb so the live preview matches
// the server render exactly. Keep the maths in sync with the Ruby module.

export const DEFAULT = { primary: "#01EACB", cta: "#01EACB", bg: "#1C2034", panel: "#2E3564" }
export const ROLES = ["primary", "cta", "bg", "panel"]
const HEX = /^#?[0-9a-fA-F]{6}$/

export function validHex(value) {
  return typeof value === "string" && HEX.test(value.trim())
}

function normalize(value) {
  return "#" + value.trim().replace(/^#/, "").toLowerCase()
}

export function sanitize(raw) {
  const out = {}
  if (!raw) return out
  for (const role of ROLES) {
    const v = raw[role]
    if (validHex(v)) out[role] = normalize(v)
  }
  return out
}

function rgb(hex) {
  const h = hex.replace(/^#/, "")
  return [h.slice(0, 2), h.slice(2, 4), h.slice(4, 6)].map((c) => parseInt(c, 16))
}

function toHex(triplet) {
  return (
    "#" +
    triplet
      .map((c) => Math.round(Math.min(255, Math.max(0, c))).toString(16).padStart(2, "0"))
      .join("")
  )
}

export function luminance(hex) {
  const lin = rgb(hex).map((c) => {
    c /= 255
    return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4)
  })
  return 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2]
}

export function contrastText(hex) {
  const l = luminance(hex)
  const contrastWhite = 1.05 / (l + 0.05)
  const contrastDark = (l + 0.05) / 0.05
  return contrastDark >= contrastWhite ? "#1C2034" : "#FFFFFF"
}

export function contrastRatio(a, b) {
  const la = luminance(a), lb = luminance(b)
  const hi = Math.max(la, lb), lo = Math.min(la, lb)
  return (hi + 0.05) / (lo + 0.05)
}

// Twin of BrandPalette#readable_ink — the brand colour made legible AS TEXT on
// a light surface, same hue, taken down only as far as it has to go. See the
// Ruby side for why contrastText cannot do this job (it answers "black or
// white?", and the point is to stay the brand colour).
export function readableInk(hex, on, minRatio = 4.5) {
  if (!validHex(hex) || !validHex(on)) return hex
  if (contrastRatio(hex, on) >= minRatio) return hex
  let step = 0
  while (step < 1) {
    step += 0.02
    const candidate = darken(hex, step)
    if (contrastRatio(candidate, on) >= minRatio) return candidate
  }
  return "#1C2034"
}

export function darken(hex, amount) {
  return toHex(rgb(hex).map((c) => c * (1 - amount)))
}

export function lighten(hex, amount) {
  return toHex(rgb(hex).map((c) => c + (255 - c) * amount))
}

export function rgba(hex, alpha) {
  const [r, g, b] = rgb(hex)
  return `rgba(${r}, ${g}, ${b}, ${alpha})`
}

export function isDefault(raw) {
  const s = sanitize(raw)
  const d = sanitize(DEFAULT)
  return ROLES.every((r) => (s[r] || d[r]) === d[r])
}

export function resolve(raw) {
  const s = sanitize(raw)
  const p = { ...DEFAULT, ...s }
  // Unset panel follows the picked background exactly (see the Ruby mirror —
  // the old lighten(bg, 13%) derivation showing an unchosen colour is the bug
  // that made panel a role).
  p.panel = s.panel || s.bg || DEFAULT.panel
  return {
    ...p,
    cta_text: contrastText(p.cta),
    cta_hover: darken(p.cta, 0.12),
    text: contrastText(p.bg),
    surface: lighten(p.bg, 0.08),
    surface_2: lighten(p.bg, 0.13),
    primary_soft: rgba(p.primary, 0.12),
    // Measured against the surface it lands on: rgba(P, 0.12) composited onto
    // white is exactly lighten(P, 0.88).
    primary_ink: readableInk(p.primary, lighten(p.primary, 0.88)),
  }
}

// CSS custom-property names, shared so the controller and helper agree.
export const CSS_VARS = {
  primary: "--brand-primary",
  cta: "--brand-cta",
  bg: "--brand-bg",
  panel: "--brand-panel",
  cta_text: "--brand-cta-text",
  cta_hover: "--brand-cta-hover",
  text: "--brand-text",
  surface: "--brand-surface",
  surface_2: "--brand-surface-2",
  primary_soft: "--brand-primary-soft",
  primary_ink: "--brand-primary-ink",
}

// Apply a resolved palette's variables onto an element's inline style.
export function applyVars(el, resolved) {
  if (!el) return
  for (const [key, varName] of Object.entries(CSS_VARS)) {
    if (resolved[key] != null) el.style.setProperty(varName, resolved[key])
  }
}

// Remove the brand variables so the element falls back to the Playverto CSS
// defaults (used when a palette returns to the default colours).
export function clearVars(el) {
  if (!el) return
  for (const varName of Object.values(CSS_VARS)) el.style.removeProperty(varName)
}

// Twin of BrandPalette.tile_gradients — the answer-icon ramp derived from the
// Verto's primary colour. Same steps as the Ruby side (a parity test pins
// them), so the live preview matches what the server will render.
export const TINT_STEPS = [ 0.82, 0.70, 0.58, 0.46, 0.34, 0.22 ]

export function tileGradients(primary) {
  if (!primary || !validHex(primary)) return TINT_STEPS.map(() => null)
  return TINT_STEPS.map((step) => {
    const from = lighten(primary, step)
    const to = lighten(primary, Math.max(step - 0.18, 0))
    return `linear-gradient(135deg, ${from}, ${to})`
  })
}
