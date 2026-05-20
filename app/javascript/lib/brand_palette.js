// Mirror of app/models/concerns/brand_palette.rb so the live preview matches
// the server render exactly. Keep the maths in sync with the Ruby module.

export const DEFAULT = { primary: "#01EACB", cta: "#01EACB", bg: "#1C2034" }
export const ROLES = ["primary", "cta", "bg"]
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
  const p = { ...DEFAULT, ...sanitize(raw) }
  return {
    ...p,
    cta_text: contrastText(p.cta),
    cta_hover: darken(p.cta, 0.12),
    text: contrastText(p.bg),
    surface: lighten(p.bg, 0.08),
    surface_2: lighten(p.bg, 0.13),
    primary_soft: rgba(p.primary, 0.12),
  }
}

// CSS custom-property names, shared so the controller and helper agree.
export const CSS_VARS = {
  primary: "--brand-primary",
  cta: "--brand-cta",
  bg: "--brand-bg",
  cta_text: "--brand-cta-text",
  cta_hover: "--brand-cta-hover",
  text: "--brand-text",
  surface: "--brand-surface",
  surface_2: "--brand-surface-2",
  primary_soft: "--brand-primary-soft",
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
