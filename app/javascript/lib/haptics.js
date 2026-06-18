// Light haptic feedback for the mobile respondent experience. Uses the
// Vibration API, which is supported on Android Chrome (and a few other Android
// browsers). It's a safe no-op where the API is unavailable — notably iOS
// Safari, which doesn't implement navigator.vibrate.
export function haptic(pattern = 12) {
  try {
    navigator.vibrate?.(pattern)
  } catch (_) {
    /* unsupported / blocked — ignore */
  }
}
