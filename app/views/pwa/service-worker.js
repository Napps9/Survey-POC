// Playverto service worker — offline support for /play/:token Vertos.
//
// Registered at /play/ scope ONLY (see app/javascript/sw_register.js), so it
// never controls the studio. Everything below is written for a respondent who
// may go offline mid-Verto, not for a creator editing artwork.
//
// Strategies:
//   • /play/:token        → network-first (short timeout) → cache fallback (offline)
//   • /assets/*           → cache-first (fingerprinted; safe to keep)
//   • Card images         → cache-on-fetch, no-cors fallback for cross-origin
//   • POST /play/:token/submit → network-first; on failure, queue in IndexedDB
//                                and return { ok: true, queued: true }
//
// Drain queue on Background Sync where supported; opportunistically on any
// fetch event and on explicit page messages elsewhere (iOS Safari fallback).

// Bump when the WORKER'S OWN behaviour changes (strategies, queue logic,
// cache layout) — the activate handler below deletes every cache that doesn't
// start with the current version. Content/markup/CSS fixes no longer need a
// bump: the player HTML is network-first, so a fresh copy (referencing fresh
// asset digests) is fetched on every online visit.
const CACHE_VERSION = "playverto-v37"
const SHELL_CACHE   = `${CACHE_VERSION}-shell`
const ASSET_CACHE   = `${CACHE_VERSION}-assets`
const PAGE_CACHE    = `${CACHE_VERSION}-pages`
const IMAGE_CACHE   = `${CACHE_VERSION}-images`

const IDB_NAME  = "playverto-queue"
const IDB_STORE = "pending_submits"
// How many offline delivery attempts a queued submit gets before it is dropped.
// Without a cap an item that can never land is retried on every same-origin GET
// for the life of the browser profile.
const MAX_QUEUE_ATTEMPTS = 25

// ── Lifecycle ────────────────────────────────────────────────────────────

self.addEventListener("install", (event) => {
  self.skipWaiting()
  event.waitUntil(caches.open(SHELL_CACHE))
})

self.addEventListener("activate", (event) => {
  event.waitUntil((async () => {
    const names = await caches.keys()
    await Promise.all(
      names.filter(n => !n.startsWith(CACHE_VERSION)).map(n => caches.delete(n))
    )
    await self.clients.claim()
  })())
})

// ── Fetch routing ────────────────────────────────────────────────────────

self.addEventListener("fetch", (event) => {
  const req = event.request
  const url = new URL(req.url)

  // Submit and consent endpoints — POST only. Consent is queued for the same
  // reason submit is: an offline decline used to be fire-and-forget, so the
  // respondent was shown the declined end-state while the server never heard
  // about it and kept everything they had refused to give.
  if (req.method === "POST" && /^\/play\/[^/]+\/(submit|consent)$/.test(url.pathname)) {
    event.respondWith(handleSubmit(req))
    return
  }

  // Non-GET requests pass through.
  if (req.method !== "GET") return

  // Media, and anything asking for a byte range, pass through untouched.
  //
  // A <video> doesn't fetch a file, it asks for ranges — and a worker that
  // answers a Range request out of fetch() hands back something the element
  // can't use: a cross-origin clip comes back opaque, carrying no 206 and no
  // Content-Range, so playback errors instead of starting. A card video that
  // never starts paints NOTHING (preload="none", and a poster only if the card
  // has one), leaving the left panel showing the Verto's brand colour — which
  // reads as "the image is broken" rather than "the video didn't load".
  //
  // Card videos are Pexels CDN URLs, so this is the path every one of them
  // takes. There's nothing to gain by intercepting them either: the clips are
  // large, and the generic networkFirst below would clone every response on
  // its way past.
  if (req.destination === "video" || req.destination === "audio" || req.headers.has("range")) return

  // Opportunistic queue drain on any same-origin GET (iOS fallback).
  if (url.origin === self.location.origin) event.waitUntil(drainQueue())

  // Player HTML — network-first so edits and unpublishes are seen on the next
  // ordinary visit; the cache only answers when the network can't, which keeps
  // the offline-after-one-visit behaviour.
  if (/^\/play\/[^/]+$/.test(url.pathname)) {
    event.respondWith(networkFirstWithTimeout(event, req, PAGE_CACHE))
    return
  }

  // Same-origin fingerprinted assets — cache-first.
  if (url.origin === self.location.origin && /^\/assets\//.test(url.pathname)) {
    event.respondWith(cacheFirst(req, ASSET_CACHE))
    return
  }

  // Active Storage blobs (same-origin) — cache-first.
  if (url.origin === self.location.origin && /^\/rails\/active_storage\//.test(url.pathname)) {
    event.respondWith(cacheFirst(req, IMAGE_CACHE))
    return
  }

  // Images (any origin) — cache-on-fetch with no-cors fallback.
  if (req.destination === "image") {
    event.respondWith(imageCache(req, event))
    return
  }

  // Fonts — cache-first.
  if (req.destination === "font" || /\.(woff2?|ttf|otf)$/i.test(url.pathname)) {
    event.respondWith(cacheFirst(req, ASSET_CACHE))
    return
  }

  // Everything else: try network, fall back to cache.
  event.respondWith(networkFirst(req, PAGE_CACHE))
})

// ── Strategies ───────────────────────────────────────────────────────────

async function cacheFirst(req, cacheName) {
  const cache = await caches.open(cacheName)
  const hit = await cache.match(req)
  if (hit) return hit
  try {
    const res = await fetch(req)
    if (res && res.ok) cache.put(req, res.clone())
    return res
  } catch (_) {
    return hit || Response.error()
  }
}

// How long the network gets before a cached copy answers a /play/:token
// navigation. Long enough for one HTML round trip on a slow mobile connection
// (the whole deck is inlined — there is no second query); short enough that a
// respondent who has a cached copy isn't left staring at a blank tab when the
// network is effectively dead.
const PAGE_NETWORK_TIMEOUT_MS = 3500

// Network-first for the player HTML. Stale-while-revalidate here was why
// edits "didn't take": the cache answered every visit, and the background
// revalidation — never held open with waitUntil — was routinely killed before
// its cache.put landed, so a returning respondent could keep a stale Verto
// forever (hard refresh, which bypasses the worker, was the only way out).
//
// A response that ARRIVED is the answer, whatever its status — a 410 for an
// unpublished Verto must reach the respondent, not be papered over with the
// cached copy (same principle as handleSubmit below). Only a clean 200 is
// worth keeping for offline; a redirected response is not, because Chrome
// refuses to satisfy a navigation from a cached redirect.
async function networkFirstWithTimeout(event, req, cacheName) {
  const cache = await caches.open(cacheName)

  const network = fetch(req).then(res => {
    // Clone before the page consumes the body; waitUntil keeps the worker
    // alive until the put lands even after we've answered — the exact hazard
    // imageCache documents for its own revalidate.
    if (res && res.ok && !res.redirected) event.waitUntil(cache.put(req, res.clone()))
    return res
  })

  const TIMED_OUT = {}
  const winner = await Promise.race([
    network.catch(() => null), // null = network failed outright
    new Promise(resolve => setTimeout(resolve, PAGE_NETWORK_TIMEOUT_MS, TIMED_OUT))
  ])
  if (winner !== TIMED_OUT && winner !== null) return winner

  const cached = await cache.match(req)
  if (cached) {
    // Timed out but still in flight: let it finish in the background so a
    // slow 200 still refreshes the cache for next time.
    if (winner === TIMED_OUT) event.waitUntil(network.catch(() => {}))
    return cached
  }

  // Nothing cached to fall back on: give the network its full time — a
  // first-ever visit on a slow connection should load slowly, not fail fast.
  try {
    return await network
  } catch (_) {
    return Response.error()
  }
}

async function networkFirst(req, cacheName) {
  const cache = await caches.open(cacheName)
  try {
    const res = await fetch(req)
    if (res && res.ok && req.method === "GET") cache.put(req, res.clone())
    return res
  } catch (_) {
    const cached = await cache.match(req)
    return cached || Response.error()
  }
}

// Images — serve the cached copy instantly, but ALWAYS refetch in the
// background so the next view gets a corrected one. Cross-origin images come
// back opaque (status 0), which is indistinguishable from a 404 or a rate
// limit, so a plain cache-first strategy could pin a broken image forever and
// leave a hard refresh as the only way out. Revalidating makes that
// self-healing at the cost of one conditional request per image per visit.
async function imageCache(req, event) {
  const cache = await caches.open(IMAGE_CACHE)
  const hit   = await cache.match(req)

  const revalidate = fetch(req).then(res => {
    if (res && (res.ok || res.type === "opaque")) cache.put(req, res.clone())
    return res
  }).catch(() => null)

  // Keep the worker alive for the refetch — otherwise it can be killed the
  // moment the cached copy is returned and the poisoned entry never heals.
  event?.waitUntil(revalidate)
  if (hit) return hit

  const res = await revalidate
  if (res) return res

  // Cross-origin retry with no-cors so we can at least keep an opaque copy.
  try {
    const fallback = await fetch(req.url, { mode: "no-cors" })
    if (fallback) cache.put(req, fallback.clone())
    return fallback
  } catch (_) {
    return Response.error()
  }
}

// ── Submit queue ─────────────────────────────────────────────────────────

// A response that ARRIVED means the network is fine — whatever it says. Only a
// request that never got an answer, or one the server says to try again later,
// is worth queueing.
//
// This used to queue on any non-2xx, so a 410 Gone (the Verto was unpublished
// or deleted while the respondent had the page open from cache) was swallowed:
// the respondent saw "Saved — will sync when you're back online", the answers
// went into IndexedDB, and drainQueue retried them forever because it only
// deleted an item on res.ok. The response was lost and nobody was told.
function retryable(status) {
  return status === 429 || status >= 500
}

async function handleSubmit(req) {
  const clone = req.clone()
  let res
  try {
    res = await fetch(req)
  } catch (_) {
    return queueSubmit(clone) // genuinely offline: no response at all
  }
  if (res.ok || !retryable(res.status)) return res // 4xx goes to the page as-is
  return queueSubmit(clone)
}

async function queueSubmit(clone) {
  try { await enqueueSubmit(clone) } catch (e) { /* best effort */ }
  if (self.registration && self.registration.sync) {
    try { await self.registration.sync.register("playverto-submit") } catch (e) { /* unsupported */ }
  }
  return new Response(
    JSON.stringify({ ok: true, queued: true }),
    { status: 202, headers: { "Content-Type": "application/json" } }
  )
}

self.addEventListener("sync", (event) => {
  if (event.tag === "playverto-submit") event.waitUntil(drainQueue())
})

self.addEventListener("message", (event) => {
  if (event.data && event.data.type === "drain-queue") {
    event.waitUntil(drainQueue())
  }
})

// ── IndexedDB helpers (no deps) ──────────────────────────────────────────

function openDB() {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(IDB_NAME, 1)
    req.onupgradeneeded = () => {
      req.result.createObjectStore(IDB_STORE, { keyPath: "id", autoIncrement: true })
    }
    req.onsuccess = () => resolve(req.result)
    req.onerror   = () => reject(req.error)
  })
}

async function enqueueSubmit(req) {
  const body = await req.text()
  const url  = req.url
  const db   = await openDB()
  return new Promise((resolve, reject) => {
    const tx = db.transaction(IDB_STORE, "readwrite")
    tx.objectStore(IDB_STORE).add({ url, body, ts: Date.now() })
    tx.oncomplete = () => resolve()
    tx.onerror    = () => reject(tx.error)
  })
}

async function readAllQueued() {
  const db = await openDB()
  return new Promise((resolve, reject) => {
    const tx    = db.transaction(IDB_STORE, "readonly")
    const store = tx.objectStore(IDB_STORE)
    const req   = store.getAll()
    req.onsuccess = () => resolve(req.result || [])
    req.onerror   = () => reject(req.error)
  })
}

async function deleteQueued(id) {
  const db = await openDB()
  return new Promise((resolve, reject) => {
    const tx = db.transaction(IDB_STORE, "readwrite")
    tx.objectStore(IDB_STORE).delete(id)
    tx.oncomplete = () => resolve()
    tx.onerror    = () => reject(tx.error)
  })
}

// Record a failed delivery attempt so drainQueue can eventually give up.
async function bumpQueuedAttempts(id, attempts) {
  const db = await openDB()
  return new Promise((resolve, reject) => {
    const tx    = db.transaction(IDB_STORE, "readwrite")
    const store = tx.objectStore(IDB_STORE)
    const get   = store.get(id)
    get.onsuccess = () => {
      const row = get.result
      if (row) { row.attempts = attempts; store.put(row) }
    }
    tx.oncomplete = () => resolve()
    tx.onerror    = () => reject(tx.error)
  })
}

let _draining = false
async function drainQueue() {
  if (_draining) return
  _draining = true
  try {
    const items = await readAllQueued()
    for (const item of items) {
      try {
        const res = await fetch(item.url, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: item.body
        })
        // Drop it on success OR on anything that will never succeed. Keeping
        // only-on-ok meant a Verto unpublished mid-flight left an item retried
        // on every same-origin GET, forever, on that respondent's device.
        if (res.ok || !retryable(res.status)) await deleteQueued(item.id)
      } catch (_) {
        // The fetch threw — usually because the device is offline, which is
        // the exact case the queue exists to survive. The attempts budget must
        // NOT burn here while offline: drainQueue fires on every same-origin
        // GET, cached pages keep working offline, and each offline page view
        // used to cost several attempts — so ~25 offline page views deleted a
        // submit the respondent had been told was saved, before they ever got
        // back online. (A request that reached the server and was refused is
        // handled above by status; this catch is only ever network failure.)
        // Only a throw while the browser believes it IS online counts against
        // the budget — that is the "can never land" case the cap is for.
        if (self.navigator && self.navigator.onLine === false) continue
        const attempts = (item.attempts || 0) + 1
        if (attempts >= MAX_QUEUE_ATTEMPTS) await deleteQueued(item.id)
        else await bumpQueuedAttempts(item.id, attempts)
      }
    }
  } finally {
    _draining = false
  }
}
