// Register the Playverto service worker at root scope so it claims /play/:token.
//
// We also nudge it to drain the offline submit queue whenever the page becomes
// visible or the network returns — covers iOS Safari which lacks Background Sync.

if ("serviceWorker" in navigator) {
  window.addEventListener("load", () => {
    navigator.serviceWorker.register("/service-worker", { scope: "/" }).catch(() => {})
  })

  const drain = () => {
    if (navigator.serviceWorker.controller) {
      navigator.serviceWorker.controller.postMessage({ type: "drain-queue" })
    }
  }

  window.addEventListener("online", drain)
  window.addEventListener("pageshow", drain)
}
