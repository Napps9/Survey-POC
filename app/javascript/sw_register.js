// Register the Playverto service worker for the RESPONDENT PLAYER ONLY.
//
// The worker exists to make /play/:token usable offline: player HTML is
// network-first with a cached fallback, assets and card imagery are cached
// hard. That is right for a respondent on a phone and wrong for a creator in
// the studio: registered at
// root scope it also controlled /surveys/* and /dashboard, where its
// cache-first image strategy pinned whatever it saw first — a swapped photo,
// or a picture whose very first fetch failed, then stayed that way until the
// creator hit a hard refresh. Nobody knows to do that.
//
// Scoping the registration to /play/ keeps the offline player intact (a
// worker's scope limits which PAGES it controls, not which URLs those pages
// may cache) and takes it off every studio page, where ordinary HTTP caching
// applies and images stay fresh on their own.
const PLAYER_SCOPE = "/play/"

if ("serviceWorker" in navigator) {
  window.addEventListener("load", () => { setUpServiceWorker() })

  // Nudge the worker to drain the offline submit queue whenever the page
  // becomes visible or the network returns — covers iOS Safari, which lacks
  // Background Sync.
  const drain = () => {
    if (navigator.serviceWorker.controller) {
      navigator.serviceWorker.controller.postMessage({ type: "drain-queue" })
    }
  }

  window.addEventListener("online", drain)
  window.addEventListener("pageshow", drain)

  // When a new worker takes control of an ALREADY-controlled page
  // (skipWaiting + clients.claim in the worker), what's on screen was
  // produced by the old worker — possibly a stale cached copy. Reload once so
  // the new worker's output reaches the respondent this visit, not next.
  //
  //  - hadController: on a first-ever visit clients.claim() also fires
  //    controllerchange, but that page came straight from the network —
  //    reloading would flash the page for every brand-new respondent.
  //  - reloaded: controllerchange can fire again (another update mid-visit);
  //    one reload is corrective, a second is a loop.
  //  - playvertoEngaged: never yank the page from someone who has started —
  //    answers live only in page memory until submit (player_controller.js
  //    sets this on the first gesture inside the player).
  const hadController = !!navigator.serviceWorker.controller
  let reloaded = false
  navigator.serviceWorker.addEventListener("controllerchange", () => {
    if (!hadController || reloaded || window.playvertoEngaged) return
    reloaded = true
    window.location.reload()
  })
}

async function setUpServiceWorker() {
  await removeStaleRootRegistration()
  try {
    await navigator.serviceWorker.register("/service-worker", { scope: PLAYER_SCOPE })
  } catch (_) { /* unsupported or blocked — the app works without it */ }
}

// Drop any worker registered before the scope was narrowed. Unregistering is
// only half of it: the caches it filled outlive the registration, so the stale
// studio imagery has to be deleted explicitly or the fix reaches nobody who
// already visited. Skipped while offline, where a respondent's cached player
// page is the only copy they have and re-registering would fail anyway.
async function removeStaleRootRegistration() {
  if (navigator.onLine === false) return
  try {
    const regs = await navigator.serviceWorker.getRegistrations()
    const stale = regs.filter(r => !new URL(r.scope).pathname.startsWith(PLAYER_SCOPE))
    if (!stale.length) return

    await Promise.all(stale.map(r => r.unregister()))
    if (!self.caches) return
    const names = await caches.keys()
    await Promise.all(
      names.filter(n => n.startsWith("playverto-")).map(n => caches.delete(n))
    )
  } catch (_) { /* best effort — never block the page on cache housekeeping */ }
}
