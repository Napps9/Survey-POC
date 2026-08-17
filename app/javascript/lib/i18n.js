// Tiny client-side translation lookup. Strings come from the server as
// window.I18N (see layouts/_i18n_js), already resolved for the current locale
// with English fallback. Supports dotted keys and %{var} interpolation.
//
// window.I18N is built from the CONTENTS of the `js:` locale namespace, not
// a `{ js: {...} }` wrapper — _i18n_js.html.erb assigns window.I18N = (the
// js: subtree), so its top-level keys are js:'s own children (ask, editor,
// player, results, …). A call here must therefore start with one of THOSE
// keys, e.g. t("editor.foo") for locale key js.editor.foo — NOT
// t("js.editor.foo"). The latter silently returns the key itself (see the
// early return below): found and fixed 8 call sites doing exactly that in
// media_picker_controller.js/emoji_picker_controller.js, 2026-08-17.
export function t(key, vars = {}) {
  const data = (typeof window !== "undefined" && window.I18N) || {}
  const val = key.split(".").reduce((o, k) => (o && o[k] != null ? o[k] : null), data)
  if (val == null) return key
  return String(val).replace(/%\{(\w+)\}/g, (_, k) => (vars[k] != null ? vars[k] : `%{${k}}`))
}
