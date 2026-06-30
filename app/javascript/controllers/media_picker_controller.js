import { Controller } from "@hotwired/stimulus"

// Modal that lets editors attach an image to a card's left panel.
// Two sources: file upload (stored as a data URL on the card JSON) and the
// curated Verto Library (asset paths under /assets/verto-library/...).
export default class extends Controller {
  static targets = [
    "backdrop", "modal", "tab", "pane",
    "fileInput", "dropzone", "uploadError",
    "libraryItem", "applyBtn", "clearBtn",
    "bgThumb", "bgRemoveBtn",
    "recommendedSection", "recommendedLabel", "recommendedGrid",
    "searchInput", "searchSection", "searchStatus", "searchGrid",
    "mediaToggle", "mediaTab"
  ]
  static values = { url: String, pexsearchUrl: String, theme: String, backgroundRecommended: Array }

  // Uploaded images are normalised before they're stored: capped in source
  // size, downscaled to a max edge, and re-encoded to a compact format. Raw
  // multi-MB photos stored as base64 data URLs were the main memory driver
  // behind the production 502s, and unbounded dimensions/formats also rendered
  // inconsistently across devices.
  static SOURCE_BYTE_CAP = 12 * 1024 * 1024 // reject absurdly large uploads outright
  static MAX_EDGE        = 1600             // longest side, px
  static ENCODE_QUALITY  = 0.82

  connect() {
    this._activeCard = null
    this._pendingUrl = null
    this._pendingVideo = null
    this._mode = "card"
    this._searchMedia = "photos"
    this._escListener = (e) => { if (e.key === "Escape") this.close() }
  }

  open(event) {
    event?.preventDefault()
    event?.stopPropagation()
    const trigger = event?.currentTarget
    const card    = trigger?.closest("[data-survey-editor-target='card']")
                 || trigger?.closest(".survey-card-wrap")
    if (!card) return
    this._mode = "card"
    this._activeCard = card
    this._pendingUrl = null
    this._pendingVideo = null
    this._setApplyEnabled(false)
    // Open on the Verto Library so the curated designs are visible straight
    // away — uploading your own image is one click away on the other tab.
    this._switchTabKey("library")
    this._setMedia("photos")            // cards can be photo or video
    this._showMediaToggle(true)

    const currentUrl = card.dataset.cardImage || card.dataset.cardVideo || ""
    this.clearBtnTarget.hidden = !currentUrl

    this._renderRecommended(this._parseUrls(card.dataset.cardRecommendedImages), "Recommended for this card")
    this._seedSearch()

    this.backdropTarget.hidden = false
    document.addEventListener("keydown", this._escListener)
  }

  // Opens the same modal but targets the Verto's backdrop instead of a card.
  openBackground(event) {
    event?.preventDefault()
    this._mode = "background"
    this._activeCard = null
    this._pendingUrl = null
    this._pendingVideo = null
    this._setApplyEnabled(false)
    this._switchTabKey("library")
    // Backgrounds are photos only — a video can't be a Verto backdrop.
    this._setMedia("photos")
    this._showMediaToggle(false)
    this.clearBtnTarget.hidden = !this._currentBg()
    this._renderRecommended(this.hasBackgroundRecommendedValue ? this.backgroundRecommendedValue : [], "Recommended backgrounds")
    this._seedSearch()
    this.backdropTarget.hidden = false
    document.addEventListener("keydown", this._escListener)
  }

  close() {
    this.backdropTarget.hidden = true
    this._activeCard = null
    this._pendingUrl = null
    this._pendingVideo = null
    this._setApplyEnabled(false)
    this.libraryItemTargets.forEach(i => i.setAttribute("aria-selected", "false"))
    if (this.hasFileInputTarget) this.fileInputTarget.value = ""
    this._clearUploadError()
    this._renderRecommended([], "")
    this._clearSearch()
    document.removeEventListener("keydown", this._escListener)
  }

  backdropClick(event) {
    if (event.target === this.backdropTarget) this.close()
  }

  switchTab(event) {
    const key = event.currentTarget.dataset.tab
    this._switchTabKey(key)
  }

  _switchTabKey(key) {
    this.tabTargets.forEach(t =>
      t.setAttribute("aria-selected", t.dataset.tab === key ? "true" : "false")
    )
    this.paneTargets.forEach(p => { p.hidden = p.dataset.pane !== key })
  }

  // ── Upload tab ─────────────────────────────────────────
  fileChosen(event) {
    const file = event.target.files?.[0]
    if (file) this._readFile(file)
  }

  dragover(event)  { event.preventDefault(); this.dropzoneTarget.classList.add("is-drag") }
  dragleave()      { this.dropzoneTarget.classList.remove("is-drag") }
  drop(event) {
    event.preventDefault()
    this.dropzoneTarget.classList.remove("is-drag")
    const file = event.dataTransfer?.files?.[0]
    if (file) this._readFile(file)
  }

  _readFile(file) {
    this._clearUploadError()
    // Uploaded images carry no photographer credit.
    this._pendingCredit = ""
    this._pendingCreditUrl = ""
    if (!file.type.startsWith("image/")) {
      this._showUploadError("That doesn't look like an image file.")
      return
    }
    if (file.size > this.constructor.SOURCE_BYTE_CAP) {
      const mb = Math.round(this.constructor.SOURCE_BYTE_CAP / (1024 * 1024))
      this._showUploadError(`That image is too large — please choose one under ${mb} MB.`)
      return
    }
    // SVGs are vector and already tiny; rasterising them on a canvas would only
    // make them bigger and blurry, so keep them as-is.
    if (file.type === "image/svg+xml") {
      this._readAsDataUrl(file)
      return
    }
    this._downscale(file)
  }

  // Draw the upload onto a canvas resized to MAX_EDGE and re-encode it to WebP
  // (JPEG fallback) so every stored image is small and a consistent format.
  _downscale(file) {
    const url = URL.createObjectURL(file)
    const img = new Image()
    img.onload = () => {
      URL.revokeObjectURL(url)
      const maxEdge = this.constructor.MAX_EDGE
      const scale = Math.min(1, maxEdge / Math.max(img.width, img.height))
      const w = Math.max(1, Math.round(img.width * scale))
      const h = Math.max(1, Math.round(img.height * scale))
      const canvas = document.createElement("canvas")
      canvas.width = w
      canvas.height = h
      const ctx = canvas.getContext("2d")
      ctx.drawImage(img, 0, 0, w, h)
      const q = this.constructor.ENCODE_QUALITY
      let out
      try {
        out = canvas.toDataURL("image/webp", q)
        // Browsers without WebP encoding silently return PNG — fall back to JPEG
        // so we never store an unexpectedly large PNG.
        if (!out.startsWith("data:image/webp")) out = canvas.toDataURL("image/jpeg", q)
      } catch (_e) {
        out = canvas.toDataURL("image/jpeg", q)
      }
      this._pendingUrl = out
      this._setApplyEnabled(true)
    }
    img.onerror = () => {
      URL.revokeObjectURL(url)
      // Couldn't decode (exotic format) — fall back to the raw file so the user
      // isn't blocked; the server-side size cap is the backstop.
      this._readAsDataUrl(file)
    }
    img.src = url
  }

  _readAsDataUrl(file) {
    const reader = new FileReader()
    reader.onload = () => {
      this._pendingUrl = reader.result
      this._setApplyEnabled(true)
    }
    reader.readAsDataURL(file)
  }

  _showUploadError(msg) {
    if (!this.hasUploadErrorTarget) return
    this.uploadErrorTarget.textContent = msg
    this.uploadErrorTarget.hidden = false
  }

  _clearUploadError() {
    if (!this.hasUploadErrorTarget) return
    this.uploadErrorTarget.textContent = ""
    this.uploadErrorTarget.hidden = true
  }

  // ── Library tab ────────────────────────────────────────
  pickLibraryItem(event) {
    const item = event.currentTarget
    this.libraryItemTargets.forEach(i => i.setAttribute("aria-selected", "false"))
    item.setAttribute("aria-selected", "true")
    if (item.dataset.video) {
      this._pendingVideo = { video: item.dataset.video, poster: item.dataset.poster || "" }
      this._pendingUrl = null
    } else {
      this._pendingUrl = item.dataset.url
      this._pendingVideo = null
    }
    // Pexels results carry a creator credit; curated/recommended tiles don't
    // (these stay empty so the credit is cleared on apply).
    this._pendingCredit    = item.dataset.credit || ""
    this._pendingCreditUrl = item.dataset.creditUrl || ""
    this._setApplyEnabled(true)
  }

  // ── Pexels search ──────────────────────────────────────
  // Debounced as the editor types; Enter searches immediately. Results are
  // fetched at the ratio of the slot being filled (this._mode → context) and
  // reuse the libraryItem target + pickLibraryItem action, so selecting one
  // behaves exactly like a curated thumbnail.
  searchKeydown(event) {
    if (event.key === "Enter") { event.preventDefault(); this._runSearch() }
  }

  // Photos ↔ Videos toggle. Re-runs the current query against the chosen
  // media type.
  switchMedia(event) {
    this._setMedia(event.currentTarget.dataset.media)
    this._runSearch()
  }

  _setMedia(media) {
    this._searchMedia = media === "videos" ? "videos" : "photos"
    if (this.hasMediaTabTarget) {
      this.mediaTabTargets.forEach(t => {
        const on = t.dataset.media === this._searchMedia
        t.classList.toggle("is-active", on)
        t.setAttribute("aria-selected", on ? "true" : "false")
      })
    }
    if (this.hasSearchInputTarget) {
      this.searchInputTarget.placeholder = this._searchMedia === "videos"
        ? "Search stock videos…" : "Search stock photos…"
    }
  }

  _showMediaToggle(show) {
    if (this.hasMediaToggleTarget) this.mediaToggleTarget.hidden = !show
  }

  // Pre-fill the search with the Verto theme and run it on open, so the picker
  // surfaces on-theme stock photos immediately instead of waiting for the
  // editor to type. The editor can refine the query at any time.
  _seedSearch() {
    if (!this.hasSearchInputTarget || !this.hasPexsearchUrlValue) return
    if (this.searchInputTarget.value.trim()) return
    const seed = (this.hasThemeValue ? this.themeValue : "").trim()
    if (!seed) return
    this.searchInputTarget.value = seed
    this._runSearch()
  }

  searchPexels() {
    clearTimeout(this._searchTimer)
    this._searchTimer = setTimeout(() => this._runSearch(), 350)
  }

  async _runSearch() {
    if (!this.hasPexsearchUrlValue || !this.hasSearchGridTarget) return
    const q = (this.hasSearchInputTarget ? this.searchInputTarget.value : "").trim()
    if (!q) { this._clearSearch(); return }

    const context = this._mode === "background" ? "background" : "card"
    const media   = this._searchMedia
    const noun    = media === "videos" ? "videos" : "photos"
    this._showSearchStatus("Searching…")
    this.searchGridTarget.replaceChildren()

    const token = (this._searchToken = (this._searchToken || 0) + 1)
    try {
      const url = `${this.pexsearchUrlValue}?q=${encodeURIComponent(q)}&context=${context}&media=${media}`
      const resp = await fetch(url, { headers: { "Accept": "application/json" } })
      const data = await resp.json()
      if (token !== this._searchToken) return // a newer search superseded this one

      const items = Array.isArray(data.images) ? data.images : []
      if (data.error === "search_unavailable") {
        this._showSearchStatus("Stock search isn’t configured.")
        return
      }
      if (!items.length) {
        this._showSearchStatus(data.error ? "Couldn’t reach the stock service." : `No ${noun} found.`)
        return
      }
      this._showSearchStatus("")
      const frag = document.createDocumentFragment()
      for (const item of items) {
        const isVideo = item && item.type === "video"
        if (!item || (!item.url && !item.video)) continue
        const btn = document.createElement("button")
        btn.type = "button"
        btn.className = isVideo ? "media-library-item is-video" : "media-library-item"
        const verb = isVideo ? "Video" : "Photo"
        btn.title = item.photographer ? `${verb} by ${item.photographer}` : (item.alt || "")
        const thumb = item.thumb || item.poster || item.url
        if (thumb) btn.style.backgroundImage = `url('${String(thumb).replace(/'/g, "\\'")}')`
        if (isVideo) {
          btn.dataset.video = item.video
          if (item.poster) btn.dataset.poster = item.poster
        } else {
          btn.dataset.url = item.url
        }
        if (item.photographer) btn.dataset.credit = item.photographer
        if (item.photographer_url) btn.dataset.creditUrl = item.photographer_url
        btn.dataset.mediaPickerTarget = "libraryItem"
        btn.dataset.action = "click->media-picker#pickLibraryItem"
        btn.setAttribute("aria-selected", "false")
        frag.appendChild(btn)
      }
      this.searchGridTarget.appendChild(frag)
    } catch (_e) {
      if (token === this._searchToken) this._showSearchStatus("Couldn’t reach the stock service.")
    }
  }

  _showSearchStatus(text) {
    if (this.hasSearchSectionTarget) this.searchSectionTarget.hidden = false
    if (this.hasSearchStatusTarget) this.searchStatusTarget.textContent = text || ""
  }

  _clearSearch() {
    clearTimeout(this._searchTimer)
    this._searchToken = (this._searchToken || 0) + 1 // invalidate in-flight results
    if (this.hasSearchInputTarget) this.searchInputTarget.value = ""
    if (this.hasSearchGridTarget) this.searchGridTarget.replaceChildren()
    if (this.hasSearchStatusTarget) this.searchStatusTarget.textContent = ""
    if (this.hasSearchSectionTarget) this.searchSectionTarget.hidden = true
  }

  // ── Apply / clear ──────────────────────────────────────
  applyImage() {
    if (!this._pendingUrl && !this._pendingVideo) return
    if (this._mode === "background") {
      // Backgrounds are photos only (the video toggle is hidden here).
      if (this._pendingUrl) { this._setVertoBackground(this._pendingUrl); this.close() }
      return
    }
    if (!this._activeCard) return
    if (this._pendingVideo) {
      this._setCardVideo(this._activeCard, this._pendingVideo.video, this._pendingVideo.poster,
        this._pendingCredit, this._pendingCreditUrl)
    } else {
      this._setCardImage(this._activeCard, this._pendingUrl, this._pendingCredit, this._pendingCreditUrl)
    }
    this._notifyDirty()
    this.close()
  }

  clearImage() {
    if (this._mode === "background") {
      this._setVertoBackground("")
      this.close()
      return
    }
    if (!this._activeCard) return
    this._setCardImage(this._activeCard, "")
    this._notifyDirty()
    this.close()
  }

  // Panel "Remove" button — clears the Verto backdrop without opening the modal.
  removeBackground(event) {
    event?.preventDefault()
    this._setVertoBackground("")
  }

  _currentBg() {
    if (!this.hasBgThumbTarget) return ""
    const bg = this.bgThumbTarget.style.backgroundImage
    return bg && bg !== "none" ? bg : ""
  }

  _setVertoBackground(url) {
    // Thumbnail + Remove button in the panel
    if (this.hasBgThumbTarget) {
      this.bgThumbTarget.style.backgroundImage = url ? `url('${url.replace(/'/g, "\\'")}')` : ""
    }
    if (this.hasBgRemoveBtnTarget) this.bgRemoveBtnTarget.hidden = !url

    // Live-apply to every canvas wrapper (editor feed + preview overlay)
    const value = url
      ? `linear-gradient(rgba(0,0,0,0.45), rgba(0,0,0,0.12) 28%, rgba(0,0,0,0.12) 72%, rgba(0,0,0,0.45)), url("${url.replace(/"/g, "")}")`
      : ""
    document.querySelectorAll('[data-brand-palette-target="preview"]').forEach((el) => {
      if (value) el.style.setProperty("--brand-bg-image", value)
      else el.style.removeProperty("--brand-bg-image")
    })

    this._saveBackground(url)
  }

  async _saveBackground(url) {
    if (!this.hasUrlValue) return
    try {
      const res = await fetch(this.urlValue, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "",
        },
        body: JSON.stringify({ background_image: url || null }),
      })
      if (!res.ok) throw new Error(`HTTP ${res.status}`)
    } catch (_e) {
      // The editor stays usable, but tell the user the backdrop didn't stick so
      // they don't publish thinking it saved (a source of draft/preview drift).
      this._flashEditor("Couldn't save the background — please try again.")
    }
  }

  // Reuse the survey-editor controller's status flash (it shares this root
  // element) so background-save failures surface like other save errors.
  _flashEditor(msg) {
    const editor = this.application.getControllerForElementAndIdentifier(this.element, "survey-editor")
    if (editor && typeof editor.flash === "function") editor.flash(msg, "text-hot-pink")
  }

  _setCardImage(card, url, credit = "", creditUrl = "") {
    card.dataset.cardImage = url || ""
    card.dataset.cardImageCredit = url ? (credit || "") : ""
    card.dataset.cardImageCreditUrl = url ? (creditUrl || "") : ""
    // Picking/clearing a photo replaces any auto-populated video on this card.
    card.dataset.cardVideo = ""
    card.dataset.cardVideoPoster = ""
    const left = card.querySelector(".split-left")
    if (!left) return
    left.querySelector(".split-left-video[data-card-media]")?.remove()
    let imgEl = left.querySelector(".split-left-img[data-card-media]")
    let ovEl  = left.querySelector(".split-left-overlay[data-card-media]")
    if (url) {
      if (!imgEl) {
        imgEl = document.createElement("div")
        imgEl.className = "split-left-img"
        imgEl.dataset.cardMedia = "true"
        left.prepend(imgEl)
      }
      imgEl.style.backgroundImage = `url('${url.replace(/'/g, "\\'")}')`
      if (!ovEl) {
        ovEl = document.createElement("div")
        ovEl.className = "split-left-overlay"
        ovEl.dataset.cardMedia = "true"
        imgEl.after(ovEl)
      }
      this._renderCardCredit(left, ovEl, credit, creditUrl)
    } else {
      imgEl?.remove()
      ovEl?.remove()
      left.querySelector(".split-left-credit[data-card-media]")?.remove()
    }
  }

  // Swap a card's left panel to an autoplaying video, mirroring the server
  // render (the autoplay-video controller handles play/pause + lazy loading).
  _setCardVideo(card, video, poster, credit = "", creditUrl = "") {
    card.dataset.cardVideo = video || ""
    card.dataset.cardVideoPoster = poster || ""
    card.dataset.cardImage = ""
    card.dataset.cardImageCredit = video ? (credit || "") : ""
    card.dataset.cardImageCreditUrl = video ? (creditUrl || "") : ""
    const left = card.querySelector(".split-left")
    if (!left) return
    left.querySelector(".split-left-img[data-card-media]")?.remove()
    left.querySelector(".split-left-video[data-card-media]")?.remove()
    if (!video) {
      left.querySelector(".split-left-overlay[data-card-media]")?.remove()
      left.querySelector(".split-left-credit[data-card-media]")?.remove()
      return
    }
    const vid = document.createElement("video")
    vid.className = "split-left-video"
    vid.dataset.cardMedia = "true"
    vid.muted = true; vid.loop = true; vid.autoplay = true
    vid.setAttribute("playsinline", "")
    vid.preload = "none"
    if (poster) vid.poster = poster
    vid.dataset.controller = "autoplay-video"
    const source = document.createElement("source")
    source.src = video
    source.type = "video/mp4"
    vid.appendChild(source)
    left.prepend(vid)

    let ovEl = left.querySelector(".split-left-overlay[data-card-media]")
    if (!ovEl) {
      ovEl = document.createElement("div")
      ovEl.className = "split-left-overlay"
      ovEl.dataset.cardMedia = "true"
      vid.after(ovEl)
    }
    this._renderCardCredit(left, ovEl, credit, creditUrl, "Video")
  }

  // Add/update/remove the subtle creator credit on a card's left panel.
  _renderCardCredit(left, afterEl, credit, creditUrl, verb = "Photo") {
    let el = left.querySelector(".split-left-credit[data-card-media]")
    if (!credit) { el?.remove(); return }
    if (!el) {
      el = document.createElement("div")
      el.className = "split-left-credit"
      el.dataset.cardMedia = "true"
      ;(afterEl || left.firstChild)?.after(el)
    }
    const label = `${verb} by ${credit}`
    if (creditUrl) {
      const a = document.createElement("a")
      a.href = creditUrl
      a.target = "_blank"
      a.rel = "noopener nofollow"
      a.textContent = label
      el.replaceChildren(a)
    } else {
      el.textContent = label
    }
  }

  _notifyDirty() {
    // The survey-editor controller listens on `input` from the editor root,
    // but image swaps don't bubble such an event — dispatch one explicitly.
    this.element.dispatchEvent(new CustomEvent("input", { bubbles: true }))
  }

  _setApplyEnabled(enabled) {
    this.applyBtnTarget.disabled = !enabled
  }

  _parseUrls(raw) {
    if (!raw) return []
    try {
      const arr = JSON.parse(raw)
      return Array.isArray(arr) ? arr.filter(u => typeof u === "string" && u.length) : []
    } catch (_e) {
      return []
    }
  }

  // Populates (or hides) the "Recommended" section at the top of the
  // Library tab. Cloned thumbnails reuse the existing libraryItem target +
  // pickLibraryItem action so selection works identically to the
  // server-rendered items below.
  _renderRecommended(urls, label) {
    if (!this.hasRecommendedSectionTarget || !this.hasRecommendedGridTarget) return
    this.recommendedGridTarget.replaceChildren()
    if (!urls.length) {
      this.recommendedSectionTarget.hidden = true
      return
    }
    if (this.hasRecommendedLabelTarget) this.recommendedLabelTarget.textContent = label
    const frag = document.createDocumentFragment()
    for (const url of urls) {
      const btn = document.createElement("button")
      btn.type = "button"
      btn.className = "media-library-item"
      btn.title = url
      btn.style.backgroundImage = `url('${url.replace(/'/g, "\\'")}')`
      btn.dataset.url = url
      btn.dataset.mediaPickerTarget = "libraryItem"
      btn.dataset.action = "click->media-picker#pickLibraryItem"
      btn.setAttribute("aria-selected", "false")
      frag.appendChild(btn)
    }
    this.recommendedGridTarget.appendChild(frag)
    this.recommendedSectionTarget.hidden = false
  }
}
