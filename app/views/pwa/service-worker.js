// Playverto service worker — offline support for /play/:token Vertos.
//
// Registered at /play/ scope ONLY (see app/javascript/sw_register.js), so it
// never controls the studio. Everything below is written for a respondent who
// may go offline mid-Verto, not for a creator editing artwork.
//
// Strategies:
//   • /play/:token        → network-first (short timeout) → cache fallback (offline)
//   • /assets/*           → cache-first (fingerprinted; safe to keep)
//   • Card images         → same-origin cache-first; cross-origin network-first
//                           (opaque responses can't be judged, so the cache is
//                           the offline fallback, never the first answer)
//   • Video / audio / any ranged request → not intercepted at all
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
//
// Bump for a CSP CHANGE TOO, even though none of this file's behaviour moved.
// A worker's own fetches are governed by the Content-Security-Policy delivered
// WITH THIS SCRIPT when it was installed, and the browser only installs a new
// worker when the script's BYTES change. So relaxing connect-src for the Pexels
// CDNs (config/initializers/content_security_policy.rb) reached new visitors
// and nobody else: every already-registered worker kept enforcing the old
// policy, kept refusing to fetch card art, and would have done so indefinitely.
// Changing this constant is what forces the reinstall that picks the policy up.
const CACHE_VERSION = "playverto-v41"
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

// Retry pacing. A drain used to re-fire every queued item at page-request rate
// with no delay — under a server brownout, fifty thousand clients doing that
// IS the outage. Failed deliveries now back off exponentially with jitter
// (5s, 10s, 20s … capped at 5 min), and a 429's Retry-After is honoured when
// the server names a wait. The opportunistic same-origin-GET drain (the iOS
// fallback for missing Background Sync) is rate-limited too; Background Sync
// and explicit page messages still drain immediately.
const RETRY_BASE_MS         = 5_000
const RETRY_MAX_MS          = 300_000
const DRAIN_MIN_INTERVAL_MS = 30_000

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

  // Opportunistic queue drain on same-origin GETs (iOS fallback), rate-limited:
  // a page with N subresources used to kick the drain N times per navigation.
  if (url.origin === self.location.origin && Date.now() - _lastDrainAt >= DRAIN_MIN_INTERVAL_MS) {
    event.waitUntil(drainQueue())
  }

  // Player HTML — network-first so edits and unpublishes are seen on the next
  // ordinary visit; the cache only answers when the network can't, which keeps
  // the offline-after-one-visit behaviour.
  if (/^\/play\/[^/]+$/.test(url.pathname)) {
    event.respondWith(networkFirstWithTimeout(event, req, PAGE_CACHE))
    return
  }

  // Same-origin fingerprinted assets — cache-first.
  if (url.origin === self.location.origin && /^\/assets\//.test(url.pathname)) {
    event.respondWith(cacheFirst(req, ASSET_CACHE, event))
    return
  }

  // Active Storage blobs (same-origin) — cache-first.
  if (url.origin === self.location.origin && /^\/rails\/active_storage\//.test(url.pathname)) {
    event.respondWith(cacheFirst(req, IMAGE_CACHE, event))
    return
  }

  // Images (any origin) — cache-on-fetch with no-cors fallback.
  if (req.destination === "image") {
    event.respondWith(imageCache(req, event))
    return
  }

  // Fonts — cache-first.
  if (req.destination === "font" || /\.(woff2?|ttf|otf)$/i.test(url.pathname)) {
    event.respondWith(cacheFirst(req, ASSET_CACHE, event))
    return
  }

  // Everything else: try network, fall back to cache.
  event.respondWith(networkFirst(req, PAGE_CACHE))
})

// ── Strategies ───────────────────────────────────────────────────────────

// Cache-first — the strategy every Active Storage blob takes, including the
// publishing organisation's logo on the player's welcome and thank-you cards.
// It never got the guarantees imageCache spells out below, and it should have:
//
//   • A failed fetch answered `Response.error()`, and an <img> handed a network
//     error paints the browser's broken-image glyph. A cache miss is not a
//     reason to fail a request — the last resort is always the plain network,
//     exactly as imageCache says. `caches.open` was unguarded for the same
//     reason: it rejects on quota, and in a partitioned third-party frame (a
//     Verto embedded in someone else's page) storage may be gone entirely, and
//     neither may take the image down with it.
//   • `cache.put` was fire-and-forget with nothing holding the worker open, so
//     on iOS — where WebKit kills an idle worker the moment it has answered —
//     the write can be lost and the next visit pays for the image again. Same
//     hazard networkFirstWithTimeout documents for its own put.
//
// This is hardening, not a diagnosis: a logo reported as a broken box in the
// field could equally be a blob whose bytes are gone (nothing here can fix
// that — see brand_logo_controller.js for the cosmetic backstop).
//
// `event` is optional so the signature stays usable from anywhere, but every
// call site passes it — without it the waitUntil is a no-op and the iOS write
// hazard is back.
async function cacheFirst(req, cacheName, event) {
  let cache = null
  try { cache = await caches.open(cacheName) } catch (_) { return fetch(req) }

  const hit = await cache.match(req).catch(() => null)
  if (hit) return hit

  try {
    const res = await fetch(req)
    // Keep the worker alive until the write lands, and swallow the rejection:
    // put() rejects on quota, and in a partitioned third-party frame (a Verto
    // embedded in someone else's page) storage may be unavailable outright.
    if (res && res.ok) event?.waitUntil(cache.put(req, res.clone()).catch(() => {}))
    return res
  } catch (_) {
    return fetch(req)
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

// Images. A cross-origin image comes back OPAQUE — status 0, no headers — which
// is indistinguishable from a 404 or a rate limit. Serving the cached copy first
// therefore can't work for them: one bad fetch (Pexels rate-limiting a burst of
// card art is enough) gets stored as though it were the photo, and every later
// visit is handed that copy. Revalidating in the background doesn't heal it
// either, because the replacement is another opaque response the worker can't
// judge. That is how a deck of card photos goes permanently grey.
//
// So: same-origin images stay cache-first, where a status means something.
// Cross-origin images are network-first with the cache as the OFFLINE fallback,
// which is what that cache is actually for.
//
// Every cache operation is guarded. caches.open and cache.put both reject in
// ordinary conditions — quota (Chrome pads opaque entries heavily), or storage
// being unavailable in a partitioned third-party frame, which is exactly what
// embedding a Verto in another page creates. A cache failure must never take the
// image request down with it, so nothing here answers with Response.error():
// the last resort is always the plain network.
async function imageCache(req, event) {
  const sameOrigin = new URL(req.url).origin === self.location.origin

  let cache = null
  try { cache = await caches.open(IMAGE_CACHE) } catch (_) { return fetch(req) }

  const keep = (res) => {
    if (!cache || !res) return
    if (!(res.ok || res.type === "opaque")) return
    // Fire-and-forget, but swallow the rejection: an unhandled one here would
    // take down the strategy that's still trying to answer the request.
    cache.put(req, res.clone()).catch(() => {})
  }

  if (sameOrigin) {
    const hit = await cache.match(req).catch(() => null)
    const revalidate = fetch(req).then(res => { keep(res); return res }).catch(() => null)
    // Keep the worker alive for the refetch — otherwise it can be killed the
    // moment the cached copy is returned and a stale entry never refreshes.
    event?.waitUntil(revalidate)
    if (hit) return hit
    const res = await revalidate
    if (res) return res
    return fetch(req)
  }

  // Cross-origin: the network is the only source whose answer can be trusted.
  try {
    const res = await fetch(req)
    keep(res)
    return res
  } catch (_) {
    const hit = await cache.match(req).catch(() => null)
    if (hit) return hit                 // offline, and we have something
    return fetch(req.url, { mode: "no-cors" })
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
  // The server answered "try again later" — schedule the first retry with
  // backoff (honouring Retry-After on a 429) instead of racing back in.
  return queueSubmit(clone, retryDelayMs(0, res.headers.get("Retry-After")))
}

// How long a failed delivery waits before its next attempt: exponential with
// full jitter, floored by whatever Retry-After the server named.
function retryDelayMs(backoffs, retryAfterHeader) {
  const exp    = Math.min(RETRY_BASE_MS * 2 ** backoffs, RETRY_MAX_MS)
  const jitter = Math.random() * exp
  const named  = Number(retryAfterHeader) * 1000 // NaN unless a seconds value
  return Math.max(exp / 2 + jitter / 2, Number.isFinite(named) ? named : 0)
}

async function queueSubmit(clone, delayMs = 0) {
  try { await enqueueSubmit(clone, delayMs) } catch (e) { /* best effort */ }
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

async function enqueueSubmit(req, delayMs = 0) {
  const body = await req.text()
  const url  = req.url
  const db   = await openDB()
  return new Promise((resolve, reject) => {
    const tx = db.transaction(IDB_STORE, "readwrite")
    tx.objectStore(IDB_STORE).add({ url, body, ts: Date.now(), nextAt: Date.now() + delayMs })
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

// Merge fields (attempt counters, the next-retry timestamp) into a queued row.
async function updateQueued(id, patch) {
  const db = await openDB()
  return new Promise((resolve, reject) => {
    const tx    = db.transaction(IDB_STORE, "readwrite")
    const store = tx.objectStore(IDB_STORE)
    const get   = store.get(id)
    get.onsuccess = () => {
      const row = get.result
      if (row) store.put(Object.assign(row, patch))
    }
    tx.oncomplete = () => resolve()
    tx.onerror    = () => reject(tx.error)
  })
}

let _draining = false
let _lastDrainAt = 0
async function drainQueue() {
  if (_draining) return
  _draining = true
  _lastDrainAt = Date.now()
  try {
    const items = await readAllQueued()
    for (const item of items) {
      // Still inside its backoff window — not this drain's business.
      if (item.nextAt && item.nextAt > Date.now()) continue
      try {
        const res = await fetch(item.url, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: item.body
        })
        // Drop it on success OR on anything that will never succeed. Keeping
        // only-on-ok meant a Verto unpublished mid-flight left an item retried
        // on every same-origin GET, forever, on that respondent's device.
        if (res.ok || !retryable(res.status)) { await deleteQueued(item.id); continue }
        // The server ANSWERED "try again later" (429/5xx) — back off
        // exponentially, honouring Retry-After. This is not the can-never-land
        // case the attempts budget below exists for, so it doesn't burn it:
        // an overloaded server must never cost a respondent their saved
        // submit, and the backoff bounds the retry rate on its own.
        const backoffs = (item.backoffs || 0) + 1
        await updateQueued(item.id, {
          backoffs,
          nextAt: Date.now() + retryDelayMs(backoffs, res.headers.get("Retry-After"))
        })
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
        else await updateQueued(item.id, {
          attempts,
          nextAt: Date.now() + retryDelayMs(attempts, null)
        })
      }
    }
  } finally {
    _draining = false
  }
}
