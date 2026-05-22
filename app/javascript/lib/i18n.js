// Tiny client-side translation lookup. Strings come from the server as
// window.I18N (see layouts/_i18n_js), already resolved for the current locale
// with English fallback. Supports dotted keys and %{var} interpolation.
export function t(key, vars = {}) {
  const data = (typeof window !== "undefined" && window.I18N) || {}
  const val = key.split(".").reduce((o, k) => (o && o[k] != null ? o[k] : null), data)
  if (val == null) return key
  return String(val).replace(/%\{(\w+)\}/g, (_, k) => (vars[k] != null ? vars[k] : `%{${k}}`))
}
