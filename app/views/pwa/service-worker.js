// Playverto service worker — offline support for /play/:token Vertos.
//
// Strategies:
//   • /play/:token        → stale-while-revalidate (card JSON is inlined in HTML)
//   • /assets/*           → cache-first (fingerprinted; safe to keep)
//   • Card images         → cache-on-fetch, no-cors fallback for cross-origin
//   • POST /play/:token/submit → network-first; on failure, queue in IndexedDB
//                                and return { ok: true, queued: true }
//
// Drain queue on Background Sync where supported; opportunistically on any
// fetch event and on explicit page messages elsewhere (iOS Safari fallback).

const CACHE_VERSION = "playverto-v1"
const SHELL_CACHE   = `${CACHE_VERSION}-shell`
const ASSET_CACHE   = `${CACHE_VERSION}-assets`
const PAGE_CACHE    = `${CACHE_VERSION}-pages`
const IMAGE_CACHE   = `${CACHE_VERSION}-images`

const IDB_NAME  = "playverto-queue"
const IDB_STORE = "pending_submits"

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

  // Submit endpoint — POST only.
  if (req.method === "POST" && /^\/play\/[^/]+\/submit$/.test(url.pathname)) {
    event.respondWith(handleSubmit(req))
    return
  }

  // Non-GET requests pass through.
  if (req.method !== "GET") return

  // Opportunistic queue drain on any same-origin GET (iOS fallback).
  if (url.origin === self.location.origin) event.waitUntil(drainQueue())

  // Player HTML — SWR so it works offline after one visit.
  if (/^\/play\/[^/]+$/.test(url.pathname)) {
    event.respondWith(staleWhileRevalidate(req, PAGE_CACHE))
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
    event.respondWith(imageCache(req))
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

async function staleWhileRevalidate(req, cacheName) {
  const cache = await caches.open(cacheName)
  const cached = await cache.match(req)
  const network = fetch(req).then(res => {
    if (res && res.ok) cache.put(req, res.clone())
    return res
  }).catch(() => null)
  return cached || (await network) || Response.error()
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

async function imageCache(req) {
  const cache = await caches.open(IMAGE_CACHE)
  const hit = await cache.match(req)
  if (hit) return hit
  try {
    const res = await fetch(req)
    if (res && (res.ok || res.type === "opaque")) cache.put(req, res.clone())
    return res
  } catch (_) {
    // Cross-origin retry with no-cors so we can at least cache an opaque copy.
    try {
      const res = await fetch(req.url, { mode: "no-cors" })
      if (res) cache.put(req, res.clone())
      return res
    } catch (__) {
      return hit || Response.error()
    }
  }
}

// ── Submit queue ─────────────────────────────────────────────────────────

async function handleSubmit(req) {
  const clone = req.clone()
  try {
    const res = await fetch(req)
    if (!res.ok) throw new Error(`HTTP ${res.status}`)
    return res
  } catch (_) {
    try { await enqueueSubmit(clone) } catch (e) { /* best effort */ }
    if (self.registration && self.registration.sync) {
      try { await self.registration.sync.register("playverto-submit") } catch (e) { /* unsupported */ }
    }
    return new Response(
      JSON.stringify({ ok: true, queued: true }),
      { status: 202, headers: { "Content-Type": "application/json" } }
    )
  }
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
        if (res.ok) await deleteQueued(item.id)
      } catch (_) { /* keep for next attempt */ }
    }
  } finally {
    _draining = false
  }
}
