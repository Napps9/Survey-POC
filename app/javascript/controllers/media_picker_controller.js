import { Controller } from "@hotwired/stimulus"
import { t } from "lib/i18n"

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
    "searchInput", "searchSection", "searchStatus", "searchGrid", "loadMore",
    "mediaToggle", "mediaTab",
    "saveToLibrary", "brandGrid", "libraryFileInput", "brandStatus",
    "lottieSection", "lottieInput", "lottieError", "lottieBtn",
    "animBgSection", "animBgColor", "animBgClear",
    "animateAssetSection", "animateAssetToggle",
    "focalSection", "focalFrame", "focalImg",
    "cropStage", "cropFrame", "cropImg", "cropZoom",
    "cropHint", "cropHintLegacy", "cropSkipBtn",
    "appealBtn", "appealStatus", "approvedSection", "approvedGrid"
  ]
  static values = { url: String, pexsearchUrl: String, moderateUrl: String, cardImageUrl: String, cardLottieUrl: String, libraryUrl: String, theme: String, backgroundRecommended: Array, appealCreateUrl: String, appealsListUrl: String }

  // Uploaded images are normalised before they're stored: capped in source
  // size, downscaled to a max edge, and re-encoded to a compact format. Raw
  // multi-MB photos stored as base64 data URLs were the main memory driver
  // behind the production 502s, and unbounded dimensions/formats also rendered
  // inconsistently across devices.
  static SOURCE_BYTE_CAP = 12 * 1024 * 1024 // reject absurdly large uploads outright
  static MAX_EDGE        = 1600             // longest side, px
  static ENCODE_QUALITY  = 0.82
  static SVG_BYTE_CAP    = 500 * 1024       // SVGs skip downscaling, so cap them directly
  // GIFs skip downscaling too (see _readFile) — capped directly at the
  // server's own Survey::CARD_IMAGE_MAX_BYTES so nothing the client accepts
  // can still be rejected once it reaches CardImageStore.decode.
  static GIF_BYTE_CAP    = 3 * 1024 * 1024

  // Fixed [width, height] output ratio per slot, matching PexelsClient::CROP_FOR
  // — a Pexels pick already arrives pre-cropped to these dimensions server-side,
  // so an upload should land on the card at the same shape. Only the modes
  // listed here get an interactive crop stage; consent/comms uploads keep
  // today's plain-downscale path (their slot isn't a fixed ratio the way a
  // card/background/tap-option art frame is).
  static CROP_RATIO = { card: [ 720, 1280 ], background: [ 1920, 1080 ], tapOption: [ 800, 800 ] }
  static CROP_ZOOM_MAX = 3 // how far past cover-fit the slider lets an editor punch in

  // Same gradient pairs _card_component.html.erb falls back to when a tap-card
  // statement has no image, so a cleared/never-set slot repaints identically
  // to a fresh server render.
  static TAP_OPTION_FILLS = [
    [ "#d4edda", "#a8d5b5" ], [ "#d1ecf1", "#9fd5df" ], [ "#fff3cd", "#ffd88a" ],
    [ "#f8d7da", "#f5a8b0" ], [ "#e2d9f3", "#c3aee8" ]
  ]

  connect() {
    this._activeCard = null
    this._pendingUrl = null
    this._pendingVideo = null
    this._mode = "card"
    this._optionIndex = null
    this._searchMedia = "photos"
    this._escListener = (e) => { if (e.key === "Escape") this.close() }
    this._cropImgEl = null
    this._pendingAppeal = null
    // The re-crop record riding with a cropped upload: the uncropped original
    // and the crop rect taken from it, stashed by cropApply and consumed by
    // the card-image branch of applyImage. Null everywhere else — a pick with
    // no record stamps none onto the card.
    this._pendingSource = null
    this._pendingCrop = null
    // The Adjust flow: true while the crop stage is re-editing a card's
    // existing photo (opened by openAdjustCrop rather than an upload), with
    // _adjustSource holding the stored original's URL so apply doesn't
    // re-persist bytes the server already has.
    this._adjustMode = false
    this._adjustSource = null
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
    this._pendingSource = null
    this._pendingCrop = null
    this._setApplyEnabled(false)

    // A range card has no photo/video/lottie slot of its own — its reaction
    // animation is swapped through the separate animation-picker modal. This
    // modal opens for such a card only for the per-card SETTINGS below (the
    // Animation background), so the source tabs/panes have nothing to act on
    // and stay hidden; openAnimBgImage() brings them back for its own "Use an
    // image" sub-flow regardless of card type.
    const isRange = card.dataset.cardType === "range"
    this._showMediaSwapUI(!isRange)
    if (isRange) {
      this.paneTargets.forEach(p => { p.hidden = true })
      this.clearBtnTarget.hidden = true
      // The colour/asset settings below all save live (_writeAnimBg calls
      // _notifyDirty itself) — there is never anything pending to Apply here
      // until "Use an image" is picked, so a permanently-disabled Apply only
      // reads as broken. openAnimBgImage() brings it back for that sub-flow.
      this.applyBtnTarget.hidden = true
    } else {
      this.applyBtnTarget.hidden = false
      // Open on the Verto Library so the curated designs are visible straight
      // away — uploading your own image is one click away on the other tab.
      this._switchTabKey("library")
      this._setMedia("photos")            // cards can be photo or video
      this._showMediaToggle(true)
      this._showLottieSection(true)       // paste-a-LottieFiles-URL, cards only

      const currentUrl = card.dataset.cardImage || card.dataset.cardVideo || card.dataset.cardLottie || ""
      this.clearBtnTarget.hidden = !currentUrl

      this._renderRecommended(this._parseUrls(card.dataset.cardRecommendedImages), "Recommended for this card")
      this._seedSearch()
      this._loadApprovedAppeals()
    }
    this._syncAnimationBg()             // backdrop, only when the panel animates
    this._syncAnimateAsset()            // push in/out loop, photo or lottie only
    this._syncFocal()                   // mobile header position, images only

    this.backdropTarget.hidden = false
    this._resetModalScroll()
    document.addEventListener("keydown", this._escListener)
  }

  // The modal is toggled with `hidden` rather than torn down, so its scroller
  // keeps whatever offset it had — and the sections above the fold (the stock
  // grid, the approved strip) un-hide ASYNCHRONOUSLY after it is already on
  // screen, pushing the view further down. Between them a creator opening Add
  // media landed part-way down the asset list, sometimes at the very bottom.
  // Called on open and again once those late sections have landed.
  _resetModalScroll() {
    const body = this.element.querySelector(".media-modal-body")
    if (!body) return
    body.scrollTop = 0
    requestAnimationFrame(() => { body.scrollTop = 0 })
  }

  // Opens the same modal for a Comms email image block. Photos only, no
  // Lottie, no per-card recommendations. Applying dispatches
  // media-picker:commsImage — comms_editor_controller owns the selected
  // block and paints it, so this controller stays survey-markup-free here.
  openComms(event) {
    event?.preventDefault()
    event?.stopPropagation()
    this._mode = "comms"
    this._activeCard = null
    this._pendingUrl = null
    this._pendingVideo = null
    this._setApplyEnabled(false)
    this._switchTabKey("upload")
    this._setMedia("photos")
    this._showMediaToggle(false)
    this._showLottieSection(false)
    this.clearBtnTarget.hidden = true
    this._renderRecommended([], "")
    this._seedSearch()
    this.backdropTarget.hidden = false
    this._resetModalScroll()
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
    this._showLottieSection(false)
    this.clearBtnTarget.hidden = !this._currentBg()
    this._renderRecommended(this.hasBackgroundRecommendedValue ? this.backgroundRecommendedValue : [], "Recommended backgrounds")
    this._seedSearch()
    this._loadApprovedAppeals()
    this.backdropTarget.hidden = false
    this._resetModalScroll()
    document.addEventListener("keydown", this._escListener)
  }

  // Opens the same modal but targets the consent gate's left panel. The gate
  // is a survey-level setting, not a card — applying dispatches to
  // gate-cards#setConsentImage, which paints the in-feed replica and persists
  // consent_image via update_settings. Photos only, like the Verto backdrop.
  openConsent(event) {
    event?.preventDefault()
    event?.stopPropagation()
    this._mode = "consent"
    this._activeCard = null
    this._pendingUrl = null
    this._pendingVideo = null
    this._setApplyEnabled(false)
    this._switchTabKey("library")
    this._setMedia("photos")
    this._showMediaToggle(false)
    this._showLottieSection(false)
    this.clearBtnTarget.hidden = !this._consentLeft()?.querySelector(".split-left-img")
    // The per-card "Recommended" list keys off a card's own content — the
    // gate has none, so lean on the theme-seeded stock search instead.
    this._renderRecommended([], "")
    this._seedSearch()
    this._loadApprovedAppeals()
    this.backdropTarget.hidden = false
    this._resetModalScroll()
    document.addEventListener("keydown", this._escListener)
  }

  _consentLeft() {
    return this.element.querySelector("[data-gate-cards-target='consentLeft']")
  }

  // Opens the same modal but targets ONE tap-card statement's image instead
  // of the card's own left-panel image/video.
  openTapOption(event) {
    event?.preventDefault()
    event?.stopPropagation()
    const trigger = event?.currentTarget
    const card    = trigger?.closest("[data-survey-editor-target='card']")
                 || trigger?.closest(".survey-card-wrap")
    const index   = parseInt(trigger?.dataset.mediaPickerOptionIndex, 10)
    if (!card || Number.isNaN(index)) return
    this._mode = "tapOption"
    this._optionIndex = index
    this._activeCard = card
    this._pendingUrl = null
    this._pendingVideo = null
    this._setApplyEnabled(false)
    this._switchTabKey("library")
    // A tap-card statement's image is a photo only — no video slot here.
    this._setMedia("photos")
    this._showMediaToggle(false)
    this._showLottieSection(false)

    const images = this._parseUrls(card.dataset.cardOptionImages)
    this.clearBtnTarget.hidden = !images[index]

    // The card-level "Recommended" list is for the card's own image, not any
    // one statement — leave it empty rather than showing designs for the
    // wrong slot.
    this._renderRecommended([], "")
    this._seedSearch()
    this._loadApprovedAppeals()

    this.backdropTarget.hidden = false
    this._resetModalScroll()
    document.addEventListener("keydown", this._escListener)
  }

  close() {
    this.backdropTarget.hidden = true
    this._activeCard = null
    this._pendingUrl = null
    this._pendingVideo = null
    this._pendingSource = null
    this._pendingCrop = null
    this._setApplyEnabled(false)
    // Reset to shown: only open()'s range-card branch ever hides these, and
    // every other entry point (openBackground/openConsent/openComms/
    // openTapOption) relies on them being visible without setting it itself.
    this._showMediaSwapUI(true)
    this.applyBtnTarget.hidden = false
    this._switchTabKey("library")
    this.libraryItemTargets.forEach(i => i.setAttribute("aria-selected", "false"))
    if (this.hasFileInputTarget) this.fileInputTarget.value = ""
    this._clearUploadError()
    this._renderRecommended([], "")
    this._renderApproved([])
    this._clearSearch()
    this._closeCropStage()
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

  // Hides the Upload/Verto Library tabs bar — irrelevant on open() for a
  // range card, which has no photo/video/lottie slot for them to fill.
  // openAnimBgImage() shows it again regardless of card type: picking a
  // backdrop image reuses these same tabs/panes.
  _showMediaSwapUI(show) {
    const tabs = this.element.querySelector(".media-modal-tabs")
    if (tabs) tabs.hidden = !show
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
    // Some browsers report a blank `type` for formats they don't recognise by
    // sniffing (HEIC/HEIF is the common case) — fall back to the extension
    // rather than rejecting a file that might be perfectly fine.
    const name = file.name || ""
    const looksLikeImage = file.type.startsWith("image/") || /\.(jpe?g|png|gif|webp|heic|heif|svg)$/i.test(name)
    if (!looksLikeImage) {
      this._showUploadError("That doesn't look like an image file.")
      return
    }
    if (file.size > this.constructor.SOURCE_BYTE_CAP) {
      const mb = Math.round(this.constructor.SOURCE_BYTE_CAP / (1024 * 1024))
      this._showUploadError(`That image is too large — please choose one under ${mb} MB.`)
      return
    }
    // HEIC/HEIF (the default iPhone photo format) can't be decoded on a canvas
    // in most browsers — Safari 17+ is the exception. Rather than silently
    // falling through to the raw-file path below and forwarding an
    // undownscaled multi-MB blob the server will likely reject anyway, say so
    // up front.
    if (file.type === "image/heic" || file.type === "image/heif" || /\.hei[cf]$/i.test(name)) {
      this._showUploadError("iPhone HEIC photos aren't supported yet — please convert to JPEG or PNG and try again.")
      return
    }
    // SVGs are vector and usually tiny; rasterising them on a canvas would only
    // make them bigger and blurry, so keep them as-is — but a hand-exported or
    // embedded-raster SVG can still be large, so cap it directly since it skips
    // the downscale step that normally bounds upload size. Bypasses the crop
    // stage entirely too, for the same reason: there's no raster to re-encode.
    if (file.type === "image/svg+xml") {
      if (file.size > this.constructor.SVG_BYTE_CAP) {
        const kb = Math.round(this.constructor.SVG_BYTE_CAP / 1024)
        this._showUploadError(`That SVG is too large — please choose one under ${kb} KB.`)
        return
      }
      this._readAsDataUrl(file)
      return
    }
    // GIFs are frame sequences — drawing one onto a canvas (what both the
    // crop stage and the plain downscale path do) captures only whichever
    // frame happened to be current, silently flattening the animation to a
    // single still. Store the original bytes untouched instead, same as SVG,
    // and skip the crop stage for the same reason: there's no single frame
    // to crop that wouldn't also freeze the animation.
    if (file.type === "image/gif" || /\.gif$/i.test(name)) {
      if (file.size > this.constructor.GIF_BYTE_CAP) {
        const mb = Math.round(this.constructor.GIF_BYTE_CAP / (1024 * 1024))
        this._showUploadError(`That GIF is too large — please choose one under ${mb} MB.`)
        return
      }
      this._readAsDataUrl(file)
      return
    }
    // A fixed-ratio slot gets an interactive crop stage; everything else
    // (consent gate, comms image block) keeps the plain downscale-and-stash
    // path this always had.
    if (this.constructor.CROP_RATIO[this._mode]) this._openCropStage(file)
    else this._downscale(file)
  }

  // Re-encodes a canvas to WebP, falling back to JPEG. Shared by the plain
  // downscale path and the crop stage's single final encode.
  _encodeCanvas(canvas) {
    const q = this.constructor.ENCODE_QUALITY
    try {
      const webp = canvas.toDataURL("image/webp", q)
      // Browsers without WebP encoding silently return PNG — fall back to JPEG
      // so we never store an unexpectedly large PNG.
      if (webp.startsWith("data:image/webp")) return webp
    } catch (_e) { /* fall through to JPEG */ }
    return canvas.toDataURL("image/jpeg", q)
  }

  // Draws an already-decoded image onto a canvas capped at MAX_EDGE on its
  // longest side and encodes it — the plain, uncropped path a fresh upload
  // (via _downscale) and a skipped crop stage both end up at.
  _downscaledDataUrl(img) {
    const maxEdge = this.constructor.MAX_EDGE
    const scale = Math.min(1, maxEdge / Math.max(img.width, img.height))
    const w = Math.max(1, Math.round(img.width * scale))
    const h = Math.max(1, Math.round(img.height * scale))
    const canvas = document.createElement("canvas")
    canvas.width = w
    canvas.height = h
    canvas.getContext("2d").drawImage(img, 0, 0, w, h)
    return this._encodeCanvas(canvas)
  }

  // Decode + downscale + re-encode, skipping the crop stage outright (used for
  // brand-library uploads, which aren't headed for any one fixed-ratio slot).
  // Both encoders complete through `done`, defaulting to the card-apply flow
  // (stash as the pending pick). The add-to-library tile passes its own
  // completion instead.
  _downscale(file, done = this._stashPending.bind(this)) {
    const url = URL.createObjectURL(file)
    const img = new Image()
    img.onload = () => {
      URL.revokeObjectURL(url)
      done(this._downscaledDataUrl(img))
    }
    img.onerror = () => {
      URL.revokeObjectURL(url)
      // Couldn't decode (exotic format) — fall back to the raw file so the user
      // isn't blocked; the server-side size cap is the backstop.
      this._readAsDataUrl(file, done)
    }
    img.src = url
  }

  // ── Crop stage ──────────────────────────────────────────
  // Sits between decode and stash for a fixed-ratio slot (card/background/
  // tap-option — see CROP_RATIO): drag to reposition, a slider to zoom, single
  // final encode straight from the ORIGINAL decoded image so quality is never
  // lost to an intermediate downscale. Runs before moderation and persistence
  // — applyImage() moderates and stores whatever _stashPending receives here,
  // same as any other pending pick, so the crop is exactly what ships.

  // Decode the file once, then open the crop UI against that one Image —
  // Skip and Apply both read from it, so nothing is decoded twice.
  _openCropStage(file) {
    const url = URL.createObjectURL(file)
    const img = new Image()
    img.onload = () => {
      this._cropObjectUrl = url
      this._cropImgEl = img
      if (this.hasCropImgTarget) this.cropImgTarget.src = url
      const [ rw, rh ] = this.constructor.CROP_RATIO[this._mode]
      if (this.hasCropFrameTarget) this.cropFrameTarget.style.aspectRatio = `${rw} / ${rh}`
      this._showCropStage(true)
      // The frame's rendered size depends on the aspect-ratio just applied —
      // defer a frame so getBoundingClientRect reflects the real layout.
      requestAnimationFrame(() => this._layoutCrop())
    }
    img.onerror = () => {
      URL.revokeObjectURL(url)
      // Couldn't decode for cropping either — degrade exactly like _downscale
      // does: forward the raw file rather than blocking the upload.
      this._readAsDataUrl(file)
    }
    img.src = url
  }

  // Cover-fits the image into the frame (never leaves a gap), centred, at
  // zoom 1 — the same starting point every time the stage opens.
  _layoutCrop() {
    if (!this._cropImgEl || !this.hasCropFrameTarget) return
    const rect = this.cropFrameTarget.getBoundingClientRect()
    this._cropFrameW = rect.width
    this._cropFrameH = rect.height
    this._cropMinScale = Math.max(
      this._cropFrameW / this._cropImgEl.naturalWidth,
      this._cropFrameH / this._cropImgEl.naturalHeight
    )
    this._cropZoomFactor = 1
    if (this.hasCropZoomTarget) this.cropZoomTarget.value = "1"
    this._cropScale = this._cropMinScale
    this._setCropOffset(
      (this._cropFrameW - this._cropImgEl.naturalWidth * this._cropScale) / 2,
      (this._cropFrameH - this._cropImgEl.naturalHeight * this._cropScale) / 2
    )
  }

  // Clamp so the image always fully covers the frame (no gap on any edge),
  // then paint.
  _setCropOffset(x, y) {
    const dispW = this._cropImgEl.naturalWidth  * this._cropScale
    const dispH = this._cropImgEl.naturalHeight * this._cropScale
    const minX = Math.min(0, this._cropFrameW - dispW)
    const minY = Math.min(0, this._cropFrameH - dispH)
    this._cropOffsetX = Math.min(0, Math.max(minX, x))
    this._cropOffsetY = Math.min(0, Math.max(minY, y))
    this._paintCropTransform()
  }

  _paintCropTransform() {
    if (!this.hasCropImgTarget) return
    this.cropImgTarget.style.transform = `translate(${this._cropOffsetX}px, ${this._cropOffsetY}px) scale(${this._cropScale})`
  }

  cropDragStart(event) {
    if (!this._cropImgEl) return
    event.preventDefault()
    // Best-effort: a pointer id the browser won't let us capture (some
    // synthetic/edge-case pointers) should still let the drag itself proceed
    // via the ordinary move/up events rather than aborting cropDragStart here.
    try { this.cropFrameTarget.setPointerCapture?.(event.pointerId) } catch (_e) { /* no-op */ }
    this._cropDragging = true
    this._cropDragStartX = event.clientX
    this._cropDragStartY = event.clientY
    this._cropDragOriginX = this._cropOffsetX
    this._cropDragOriginY = this._cropOffsetY
  }

  cropDrag(event) {
    if (!this._cropDragging) return
    event.preventDefault()
    this._setCropOffset(
      this._cropDragOriginX + (event.clientX - this._cropDragStartX),
      this._cropDragOriginY + (event.clientY - this._cropDragStartY)
    )
  }

  cropDragEnd(event) {
    if (!this._cropDragging) return
    this._cropDragging = false
    try { this.cropFrameTarget.releasePointerCapture?.(event.pointerId) } catch (_e) { /* no-op */ }
  }

  // Zoom slider: 1 = cover-fit, CROP_ZOOM_MAX = punched all the way in.
  // Re-anchors on the frame's centre point (in image space) so zooming feels
  // centred instead of yanking the image toward the top-left corner.
  cropZoomChanged(event) {
    if (!this._cropImgEl) return
    const factor = parseFloat(event.target.value) || 1
    const oldScale = this._cropScale
    const cx = (this._cropFrameW / 2 - this._cropOffsetX) / oldScale
    const cy = (this._cropFrameH / 2 - this._cropOffsetY) / oldScale
    this._cropScale = this._cropMinScale * factor
    this._setCropOffset(
      this._cropFrameW / 2 - cx * this._cropScale,
      this._cropFrameH / 2 - cy * this._cropScale
    )
  }

  // Output canvas size for the active slot: the mode's fixed ratio, scaled
  // down (never up) so its longest edge respects MAX_EDGE — mirrors how the
  // plain downscale path bounds its own output.
  _cropOutputDims() {
    const [ rw, rh ] = this.constructor.CROP_RATIO[this._mode]
    const scale = Math.min(1, this.constructor.MAX_EDGE / Math.max(rw, rh))
    return [ Math.max(1, Math.round(rw * scale)), Math.max(1, Math.round(rh * scale)) ]
  }

  // Single encode straight from the original decoded image: the frame's
  // current pan/zoom converts directly to a source rectangle, drawn once onto
  // the target-sized canvas — no intermediate downscale to lose quality to.
  cropApply(event) {
    event?.preventDefault()
    if (!this._cropImgEl) return
    const srcX = -this._cropOffsetX / this._cropScale
    const srcY = -this._cropOffsetY / this._cropScale
    const srcW = this._cropFrameW / this._cropScale
    const srcH = this._cropFrameH / this._cropScale
    const [ outW, outH ] = this._cropOutputDims()
    const canvas = document.createElement("canvas")
    canvas.width = outW
    canvas.height = outH
    canvas.getContext("2d").drawImage(this._cropImgEl, srcX, srcY, srcW, srcH, 0, 0, outW, outH)
    const dataUrl = this._encodeCanvas(canvas)

    // What re-cropping later needs, and the single encode above destroys: the
    // uncropped original (bounded by the same MAX_EDGE downscale as any plain
    // upload — an Adjust pass reuses the stored path instead of re-encoding
    // bytes the server already has) and where this crop sits in it, as
    // fractions of the natural size so the record survives any resize of the
    // stored source. Card heroes only for now: a tap option or background has
    // no Adjust entry point yet, and an unconsumed record on those modes
    // would be a stale thing waiting for a code path to trip over it.
    let source = null
    let crop = null
    if (this._mode === "card") {
      const nw = this._cropImgEl.naturalWidth
      const nh = this._cropImgEl.naturalHeight
      const clamp01 = (v) => Math.min(1, Math.max(0, v))
      crop = { x: clamp01(srcX / nw), y: clamp01(srcY / nh),
               w: clamp01(srcW / nw), h: clamp01(srcH / nh) }
      source = this._adjustSource || this._downscaledDataUrl(this._cropImgEl)
    }
    const adjusting = this._adjustMode
    this._closeCropStage()
    this._stashPending(dataUrl, source, crop)
    // The Adjust flow opened the stage directly — the picker's tabs and its
    // Apply button were never on screen — so confirming the crop IS the apply.
    if (adjusting) this.applyImage()
  }

  // "Skip" — today's behaviour, unchanged: the plain MAX_EDGE-capped
  // downscale of the whole original image, no fixed ratio forced on it.
  // No re-crop record either: the stored image IS the whole original, so a
  // later Adjust has everything it needs through the legacy path already.
  //
  // In the Adjust flow this button reads "Cancel" (relabelled at open):
  // the stage is re-editing a photo already on the card, nothing is
  // pending, and the card must leave exactly as it came.
  cropSkip(event) {
    event?.preventDefault()
    if (!this._cropImgEl) return
    if (this._adjustMode) {
      this._closeCropStage()
      this.close()
      return
    }
    const dataUrl = this._downscaledDataUrl(this._cropImgEl)
    this._closeCropStage()
    this._stashPending(dataUrl)
  }

  // "Adjust crop" on a card that already carries a photo: reopen the crop
  // stage seeded from the kept original (image_source) and the stored rect
  // (image_crop), so the frame can move AND widen — the owner's ask was
  // exactly that you shouldn't have to remove and re-upload to re-frame.
  // On a legacy card (nothing kept — pre-feature uploads, Skip'd uploads)
  // the current image stands in as the source: reposition and zoom IN are
  // real, zoom OUT has no pixels to reach, and the hint says so. Applying
  // from that state promotes the current image to the kept source, so the
  // NEXT adjust has the full record.
  //
  // The stage opens directly — no tabs, no Library, no modal Apply button —
  // so "Use this crop" applies immediately and "Skip" reads Cancel.
  openAdjustCrop(event) {
    event?.preventDefault()
    event?.stopPropagation()
    const trigger = event?.currentTarget
    const card    = trigger?.closest("[data-survey-editor-target='card']")
                 || trigger?.closest(".survey-card-wrap")
    if (!card) return
    const source = card.dataset.cardImageSource || card.dataset.cardImage
    // Same-origin only (a stored path or inline data URL): drawing a
    // cross-origin image taints the canvas and the final encode throws.
    // The fab is hidden for such cards; this is the belt to that brace.
    if (!source || !(source.startsWith("/") || source.startsWith("data:"))) return
    const legacy = !card.dataset.cardImageSource

    this._mode = "card"
    this._activeCard = card
    this._pendingUrl = null
    this._pendingVideo = null
    this._pendingSource = null
    this._pendingCrop = null
    // The picture doesn't change identity when its framing does — keep the
    // credit it already carries rather than wiping it with a stale pending.
    this._pendingCredit    = card.dataset.cardImageCredit || ""
    this._pendingCreditUrl = card.dataset.cardImageCreditUrl || ""
    this._setApplyEnabled(false)
    this._adjustMode = true
    this._adjustSource = source

    let rect = null
    if (!legacy && card.dataset.cardImageCrop) {
      try { rect = JSON.parse(card.dataset.cardImageCrop) } catch (_e) { rect = null }
    }

    if (this.hasCropHintTarget) this.cropHintTarget.hidden = legacy
    if (this.hasCropHintLegacyTarget) this.cropHintLegacyTarget.hidden = !legacy
    if (this.hasCropSkipBtnTarget && this.cropSkipBtnTarget.dataset.cancelLabel) {
      this.cropSkipBtnTarget.textContent = this.cropSkipBtnTarget.dataset.cancelLabel
    }

    // Stage up immediately (empty), THEN decode — opening on image load
    // would flash the picker's tabs for however long the decode takes.
    this._showCropStage(true)
    this.backdropTarget.hidden = false
    document.addEventListener("keydown", this._escListener)

    const img = new Image()
    img.onload = () => {
      if (!this._adjustMode) return // closed while decoding
      this._cropImgEl = img
      if (this.hasCropImgTarget) this.cropImgTarget.src = source
      const [ rw, rh ] = this.constructor.CROP_RATIO[this._mode]
      if (this.hasCropFrameTarget) this.cropFrameTarget.style.aspectRatio = `${rw} / ${rh}`
      requestAnimationFrame(() => {
        this._layoutCrop()
        if (rect) this._seedCrop(rect)
      })
    }
    // The stored source didn't decode — there is nothing to adjust against,
    // and an empty stuck stage would read as broken.
    img.onerror = () => this.close()
    img.src = source
  }

  // Reproduce a stored crop in the stage: scale so the rect's width fills
  // the frame, offsets so its top-left sits on the frame's origin. Clamped
  // to the slider's own range, so a rect that maths outside it (rounding,
  // a source swapped underneath) lands on the nearest legal state instead
  // of a broken transform. Runs after _layoutCrop, which owns the frame
  // measurements and the min scale this builds on.
  _seedCrop(rect) {
    const w = parseFloat(rect?.w)
    if (!this._cropImgEl || !(w > 0)) return
    const nw = this._cropImgEl.naturalWidth
    const nh = this._cropImgEl.naturalHeight
    const max = this._cropMinScale * this.constructor.CROP_ZOOM_MAX
    this._cropScale = Math.min(max, Math.max(this._cropMinScale, this._cropFrameW / (w * nw)))
    this._cropZoomFactor = this._cropScale / this._cropMinScale
    if (this.hasCropZoomTarget) this.cropZoomTarget.value = String(this._cropZoomFactor)
    this._setCropOffset(
      -(parseFloat(rect?.x) || 0) * nw * this._cropScale,
      -(parseFloat(rect?.y) || 0) * nh * this._cropScale
    )
  }

  _showCropStage(show) {
    if (this.hasCropStageTarget) this.cropStageTarget.hidden = !show
    // The crop stage takes over the modal's content area — the normal
    // tabs/body/foot (Upload/Library, Cancel/Apply) sit this out meanwhile.
    const tabs = this.element.querySelector(".media-modal-tabs")
    const body = this.element.querySelector(".media-modal-body")
    const foot = this.element.querySelector(".media-modal-foot")
    if (tabs) tabs.hidden = show
    if (body) body.hidden = show
    if (foot) foot.hidden = show
  }

  _closeCropStage() {
    this._showCropStage(false)
    if (this._cropObjectUrl) URL.revokeObjectURL(this._cropObjectUrl)
    this._cropObjectUrl = null
    this._cropImgEl = null
    this._adjustMode = false
    this._adjustSource = null
    // Restore the stage's ordinary copy — the Adjust flow may have swapped
    // the hint (legacy zoom-in-only note) and relabelled Skip as Cancel.
    if (this.hasCropHintTarget) this.cropHintTarget.hidden = false
    if (this.hasCropHintLegacyTarget) this.cropHintLegacyTarget.hidden = true
    if (this.hasCropSkipBtnTarget && this.cropSkipBtnTarget.dataset.skipLabel) {
      this.cropSkipBtnTarget.textContent = this.cropSkipBtnTarget.dataset.skipLabel
    }
    if (this.hasCropImgTarget) {
      this.cropImgTarget.removeAttribute("src")
      this.cropImgTarget.style.transform = ""
    }
  }

  _readAsDataUrl(file, done = this._stashPending.bind(this)) {
    const reader = new FileReader()
    reader.onload = () => done(reader.result)
    reader.readAsDataURL(file)
  }

  _stashPending(dataUrl, source = null, crop = null) {
    this._pendingUrl = dataUrl
    // Only cropApply passes these; every other stash — Skip's plain
    // downscale, a decode fallback, a brand-library upload — carries no
    // re-crop record and clears whatever an earlier crop left behind.
    this._pendingSource = source
    this._pendingCrop = crop
    this._setApplyEnabled(true)
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
    this._pendingAppeal = null
    if (this.hasAppealBtnTarget) {
      this.appealBtnTarget.hidden = true
      this.appealBtnTarget.disabled = false
    }
    this._setAppealStatus("")
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
    // A tile pick replaces whatever a crop stashed — including its re-crop
    // record. Left set, a Library pick made AFTER cropping an upload would
    // carry the upload's original and rect onto a picture they belong to
    // not at all.
    this._pendingSource = null
    this._pendingCrop = null
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
  //
  //
  // Theme only. Shuffle's direction prompt deliberately does NOT join it: a
  // steer belongs to the shuffle it was typed for, and seeding the picker from
  // one would mean a sentence typed minutes ago silently deciding what this
  // search returns.
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

  // The Load more button. Walks to the next page of the SAME query and appends,
  // so what the creator has already scrolled past stays put.
  loadMoreStock(event) {
    event?.preventDefault()
    this._runSearch((this._searchPage || 1) + 1)
  }

  async _runSearch(page = 1) {
    if (!this.hasPexsearchUrlValue || !this.hasSearchGridTarget) return
    const q = (this.hasSearchInputTarget ? this.searchInputTarget.value : "").trim()
    if (!q) { this._clearSearch(); return }

    const context = this._mode === "background" ? "background" : "card"
    const media   = this._searchMedia
    const noun    = media === "videos" ? "videos" : "photos"
    const append  = page > 1
    this._showSearchStatus(append ? "" : "Searching…")
    this._showLoadMore(false)
    // Page 1 is a NEW search and replaces the grid; later pages extend it.
    if (!append) this.searchGridTarget.replaceChildren()

    const token = (this._searchToken = (this._searchToken || 0) + 1)
    try {
      const url = `${this.pexsearchUrlValue}?q=${encodeURIComponent(q)}&context=${context}&media=${media}&page=${page}`
      const resp = await fetch(url, { headers: { "Accept": "application/json" } })
      const data = await resp.json()
      if (token !== this._searchToken) return // a newer search superseded this one
      this._searchPage = Number(data.page) || page

      const items = Array.isArray(data.images) ? data.images : []
      // Our OWN rate limiter, not a Pexels problem. This used to fall through
      // to the generic branch below and report "Couldn't reach the stock
      // service", which is how a creator spent a morning believing the stock
      // server was down. Show the server's own message instead.
      if (resp.status === 429 || data.code === "rate_limited") {
        this._showSearchStatus(data.error || "You've searched a lot recently — give it a few minutes.")
        return
      }
      if (data.error === "search_unavailable") {
        this._showSearchStatus("Stock search isn’t configured.")
        return
      }
      if (data.error === "search_blocked") {
        this._showSearchStatus("Try different words — that search isn’t age-appropriate for this Verto.")
        return
      }
      if (!items.length) {
        // On a later page an empty result just means the well ran dry; only say
        // so from page 1, where it's the answer to what the creator asked.
        if (append) { this._showLoadMore(false); return }
        this._showSearchStatus(data.error ? "Couldn’t reach the stock service." : `No ${noun} found.`)
        return
      }
      this._showSearchStatus("")
      const frag = document.createDocumentFragment()
      for (const item of items) {
        const tile = this._stockTile(item)
        if (tile) frag.appendChild(tile)
      }
      this.searchGridTarget.appendChild(frag)
      this._showLoadMore(data.more !== false)
    } catch (_e) {
      if (token === this._searchToken) this._showSearchStatus("Couldn’t reach the stock service.")
    }
  }

  // One stock result tile. Returns null for a result with nothing to show.
  _stockTile(item) {
    const isVideo = item && item.type === "video"
    if (!item || (!item.url && !item.video)) return null
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
      // Preview on hover. The playable mp4 already rides on the tile for the
      // apply path, so this costs no extra request until someone points at it.
      btn.addEventListener("mouseenter", () => this._previewVideo(btn))
      btn.addEventListener("mouseleave", () => this._stopPreview(btn))
      btn.addEventListener("focus", () => this._previewVideo(btn))
      btn.addEventListener("blur", () => this._stopPreview(btn))
    } else {
      btn.dataset.url = item.url
    }
    if (item.photographer) btn.dataset.credit = item.photographer
    if (item.photographer_url) btn.dataset.creditUrl = item.photographer_url
    btn.dataset.mediaPickerTarget = "libraryItem"
    btn.dataset.action = "click->media-picker#pickLibraryItem"
    btn.setAttribute("aria-selected", "false")
    return btn
  }

  // Muted, looping, inline — a thumbnail that moves, not a player. Held back
  // behind a short dwell so sweeping the pointer across the grid doesn't kick
  // off a dozen downloads, and skipped entirely when the viewer has asked for
  // reduced motion or the device can't hover (a touch "hover" is a tap, which
  // is the apply gesture).
  _previewVideo(btn) {
    if (!btn.dataset.video || btn.querySelector("video")) return
    if (window.matchMedia("(prefers-reduced-motion: reduce), (hover: none)").matches) return
    clearTimeout(btn._previewTimer)
    btn._previewTimer = setTimeout(() => {
      if (btn.querySelector("video")) return
      const vid = document.createElement("video")
      vid.className = "media-library-preview"
      vid.src = btn.dataset.video
      vid.muted = true
      vid.loop = true
      vid.playsInline = true
      vid.preload = "metadata"
      if (btn.dataset.poster) vid.poster = btn.dataset.poster
      btn.appendChild(vid)
      vid.play().catch(() => { /* autoplay refused — the poster still shows */ })
    }, 180)
  }

  _stopPreview(btn) {
    clearTimeout(btn._previewTimer)
    const vid = btn.querySelector("video")
    if (!vid) return
    vid.pause()
    vid.remove()
  }

  _showLoadMore(show) {
    if (!this.hasLoadMoreTarget) return
    this.loadMoreTarget.hidden = !show
  }

  _showSearchStatus(text) {
    // Un-hiding the stock section inserts a grid ABOVE everything already laid
    // out, so the view has to be pulled back to the top with it.
    const wasHidden = this.hasSearchSectionTarget && this.searchSectionTarget.hidden
    if (this.hasSearchSectionTarget) this.searchSectionTarget.hidden = false
    if (wasHidden) this._resetModalScroll()
    if (this.hasSearchStatusTarget) this.searchStatusTarget.textContent = text || ""
  }

  _clearSearch() {
    clearTimeout(this._searchTimer)
    this._searchToken = (this._searchToken || 0) + 1 // invalidate in-flight results
    this._searchPage = 1
    this._showLoadMore(false)
    if (this.hasSearchInputTarget) this.searchInputTarget.value = ""
    if (this.hasSearchGridTarget) this.searchGridTarget.replaceChildren()
    if (this.hasSearchStatusTarget) this.searchStatusTarget.textContent = ""
    if (this.hasSearchSectionTarget) this.searchSectionTarget.hidden = true
  }

  // ── Apply / clear ──────────────────────────────────────
  async applyImage() {
    if (!this._pendingUrl && !this._pendingVideo) return

    // Uploaded images (data URLs) can't be word-filtered like Pexels picks, so
    // they get a PG / age-appropriateness check before they're ever applied.
    if (this._pendingUrl && this._pendingUrl.startsWith("data:")) {
      const ok = await this._moderateUpload(this._pendingUrl)
      if (!ok) return // reason already shown on the upload pane

      // Admin opt-in: also file this (already-moderated) upload in the org's
      // brand library. Best-effort — a library failure never blocks the apply.
      if (this.hasSaveToLibraryTarget && this.saveToLibraryTarget.checked) {
        this._saveToLibrary(this._pendingUrl)
      }

      // Store the bytes once and carry a short path on the card instead of the
      // base64. Inline data-URLs were the memory driver behind the 502s.
      this._pendingUrl = await this._persistUpload(this._pendingUrl)
    }

    if (this._mode === "background") {
      // Backgrounds are photos only (the video toggle is hidden here).
      if (this._pendingUrl) { this._setVertoBackground(this._pendingUrl); this.close() }
      return
    }
    if (this._mode === "consent") {
      // Consent gate is photos only (the video toggle is hidden here).
      if (this._pendingUrl) {
        this.dispatch("consentImage", { detail: {
          url: this._pendingUrl,
          credit: this._pendingCredit || "",
          creditUrl: this._pendingCreditUrl || ""
        } })
        this.close()
      }
      return
    }
    if (this._mode === "comms") {
      // Email image blocks are photos only (the video toggle is hidden here).
      if (this._pendingUrl) {
        this.dispatch("commsImage", { detail: {
          url: this._pendingUrl,
          credit: this._pendingCredit || "",
          creditUrl: this._pendingCreditUrl || ""
        } })
        this.close()
      }
      return
    }
    if (!this._activeCard) return
    if (this._mode === "animBg") {
      // Behind the animation, not instead of it — the card's own lottie/range
      // media is untouched.
      if (this._pendingUrl) this._writeAnimBg({ ...this._readAnimBg(), image: this._pendingUrl })
      this.close()
      return
    }
    if (this._mode === "tapOption") {
      // Tap-card statements are photos only (the video toggle stays hidden
      // for this mode), so there's nothing to check for _pendingVideo here.
      if (this._pendingUrl) this._setTapOptionImage(this._activeCard, this._optionIndex, this._pendingUrl)
      this._notifyDirty()
      this.close()
      return
    }
    if (this._pendingVideo) {
      this._setCardVideo(this._activeCard, this._pendingVideo.video, this._pendingVideo.poster,
        this._pendingCredit, this._pendingCreditUrl)
    } else {
      // The crop stage's re-crop record: persist the uncropped original too,
      // so "Adjust crop" can zoom back OUT of this crop later (an Adjust
      // re-crop arrives holding the already-stored path — nothing to do).
      // Its moderation is QUIET: the crop that actually ships was checked
      // above; a source that fails is simply not kept, and the card degrades
      // to the legacy remove-and-reupload behaviour instead of blocking an
      // apply whose visible image already passed.
      let source = this._pendingSource
      if (source && source.startsWith("data:")) {
        if (await this._moderateUpload(source, { quiet: true })) {
          source = await this._persistUpload(source)
        } else {
          source = null
        }
      }
      const crop = source ? this._pendingCrop : null
      this._setCardImage(this._activeCard, this._pendingUrl, this._pendingCredit, this._pendingCreditUrl,
        { source, crop })
    }
    this._notifyDirty()
    this.close()
  }

  // Hand the moderated upload to the server, which stores it and returns a
  // short same-origin path to put on the card. Returns that path, or the
  // original data URL if anything goes wrong — the server still accepts inline
  // base64, so a storage hiccup degrades to the old behaviour rather than
  // blocking a creator mid-edit.
  async _persistUpload(dataUrl) {
    if (!this.hasCardImageUrlValue) return dataUrl
    try {
      const res = await fetch(this.cardImageUrlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || ""
        },
        body: JSON.stringify({ image: dataUrl })
      })
      const data = await res.json().catch(() => ({}))
      return data.ok && data.url ? data.url : dataUrl
    } catch (_) {
      return dataUrl
    }
  }

  // POST the uploaded image for a content-safety verdict. Returns true to
  // allow. Fails safe: with no endpoint wired we don't block; a call that
  // errors or comes back unsafe blocks the upload with a message.
  //
  // `quiet` is for checks whose failure only degrades a feature rather than
  // blocking the visible apply (the re-crop source): no error banner, no
  // appeal offer, no Apply-button churn — just the verdict.
  async _moderateUpload(dataUrl, { quiet = false } = {}) {
    if (!this.hasModerateUrlValue) return true
    if (!quiet) {
      this._clearUploadError()
      this._setApplyEnabled(false)
    }
    try {
      const res = await fetch(this.moderateUrlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || ""
        },
        body: JSON.stringify({ image: dataUrl })
      })
      const data = await res.json().catch(() => ({}))
      if (data.ok) return true
      if (quiet) return false
      this._showUploadError(data.reason || "That image can’t be used — it isn’t PG or age-appropriate for this Verto.")
      // Offer the appeal escape hatch only when the server marked this
      // particular verdict appealable AND this page has somewhere to send
      // one (the Comms builder mounts this same controller with no survey
      // behind it, so appealCreateUrlValue is simply absent there).
      if (data.appealable && this.hasAppealCreateUrlValue && this.hasAppealBtnTarget) {
        this._pendingAppeal = { dataUrl, reason: data.reason || "" }
        this.appealBtnTarget.hidden = false
      }
      return false
    } catch (_) {
      if (!quiet) this._showUploadError("We couldn’t check that image — please try again.")
      return false
    } finally {
      if (!quiet) this._setApplyEnabled(true)
    }
  }

  // ── Appeals ─────────────────────────────────────────────
  // The escape hatch for a rejection ImageModerator got wrong: resend the
  // SAME rejected image and its reason to platform staff (never re-run the
  // moderator — that verdict is exactly what's being appealed). Decisions
  // happen in ImageReviewsController, behind the staff routing constraint;
  // this controller only ever sees "pending" until a later page load shows
  // the result in the approved strip.
  async requestReview(event) {
    event?.preventDefault()
    if (!this._pendingAppeal || !this.hasAppealCreateUrlValue) return

    const note = (window.prompt(t("editor.appeal_note_prompt")) || "").trim()
    this.appealBtnTarget.disabled = true
    this._setAppealStatus(t("editor.appeal_submitting"))
    try {
      const res = await fetch(this.appealCreateUrlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || ""
        },
        body: JSON.stringify({ image: this._pendingAppeal.dataUrl, reason: this._pendingAppeal.reason, note })
      })
      const data = await res.json().catch(() => ({}))
      if (!data.ok) throw new Error(data.error || "appeal failed")
      this.appealBtnTarget.hidden = true
      this._setAppealStatus(t("editor.appeal_submitted"))
      this._pendingAppeal = null
    } catch (_e) {
      this.appealBtnTarget.disabled = false
      this._setAppealStatus(t("editor.appeal_failed"))
    }
  }

  _setAppealStatus(text) {
    if (!this.hasAppealStatusTarget) return
    this.appealStatusTarget.textContent = text || ""
    this.appealStatusTarget.hidden = !text
  }

  // This survey's already-approved appeals, for the Library tab's "Approved
  // by review" strip. Fetched fresh on every open() rather than rendered
  // server-side, so a decision staff made after this page loaded still shows
  // up without a reload. Best-effort: a failed fetch just leaves the strip
  // empty, same as an empty result would.
  async _loadApprovedAppeals() {
    if (!this.hasAppealsListUrlValue || !this.hasApprovedGridTarget) return
    try {
      const res = await fetch(this.appealsListUrlValue, { headers: { "Accept": "application/json" } })
      const data = await res.json().catch(() => ({}))
      this._renderApproved(Array.isArray(data.images) ? data.images : [])
    } catch (_e) {
      this._renderApproved([])
    }
  }

  // Tiles apply exactly like any other library item: pickLibraryItem sets a
  // same-origin URL as the pending pick, so re-applying an approved appeal
  // never re-moderates (applyImage only checks data: URLs).
  _renderApproved(images) {
    if (!this.hasApprovedSectionTarget || !this.hasApprovedGridTarget) return
    this.approvedGridTarget.replaceChildren()
    if (!images.length) {
      this.approvedSectionTarget.hidden = true
      return
    }
    const frag = document.createDocumentFragment()
    for (const image of images) {
      if (!image?.url) continue
      const btn = document.createElement("button")
      btn.type = "button"
      btn.className = "media-library-item"
      btn.style.backgroundImage = `url('${image.url.replace(/'/g, "\\'")}')`
      btn.dataset.url = image.url
      btn.dataset.mediaPickerTarget = "libraryItem"
      btn.dataset.action = "click->media-picker#pickLibraryItem"
      btn.setAttribute("aria-selected", "false")
      frag.appendChild(btn)
    }
    this.approvedGridTarget.appendChild(frag)
    this.approvedSectionTarget.hidden = false
  }

  // ── Brand library ──────────────────────────────────────
  chooseLibraryFile(event) {
    event.preventDefault()
    if (this.hasLibraryFileInputTarget) this.libraryFileInputTarget.click()
  }

  // Upload straight into the org's brand library from the picker (admin
  // only — the tile and input only render for admins). Same downscale +
  // moderation pipeline as a card upload; nothing is applied to the card.
  libraryFileChosen(event) {
    const file = event.target.files?.[0]
    event.target.value = ""
    if (!file) return
    if (file.size > this.constructor.SOURCE_BYTE_CAP) {
      this._brandStatus(t("editor.library_save_failed"))
      return
    }
    const done = async (dataUrl) => {
      this._brandStatus(t("editor.library_saving"))
      const ok = await this._moderateLibraryUpload(dataUrl)
      if (!ok) return
      await this._saveToLibrary(dataUrl)
    }
    // Same reasoning as _readFile: a canvas re-encode captures only one frame
    // of a GIF, silently freezing it. Store the brand-library asset untouched.
    if (file.type === "image/svg+xml" || file.type === "image/gif") this._readAsDataUrl(file, done)
    else this._downscale(file, done)
  }

  // Moderation twin of _moderateUpload with feedback on the library section
  // (the upload pane's error area lives on the other tab).
  async _moderateLibraryUpload(dataUrl) {
    if (!this.hasModerateUrlValue) return true
    try {
      const res = await fetch(this.moderateUrlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || ""
        },
        body: JSON.stringify({ image: dataUrl })
      })
      const data = await res.json().catch(() => ({}))
      if (data.ok) return true
      this._brandStatus(data.reason || t("editor.library_save_failed"))
      return false
    } catch (_) {
      this._brandStatus(t("editor.library_save_failed"))
      return false
    }
  }

  // POST an (already-moderated) data URL to the org brand library and surface
  // the new tile immediately. Best-effort by design: callers never block a
  // card apply on this.
  async _saveToLibrary(dataUrl) {
    if (!this.hasLibraryUrlValue || !this.libraryUrlValue) return
    try {
      const res = await fetch(this.libraryUrlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || ""
        },
        body: JSON.stringify({ image: dataUrl })
      })
      const data = await res.json().catch(() => ({}))
      if (!data.ok) {
        this._brandStatus(data.error || t("editor.library_save_failed"))
        return
      }
      this._brandStatus("")
      this._prependBrandTile(data)
    } catch (_) {
      this._brandStatus(t("editor.library_save_failed"))
    }
  }

  // Builds the same shape the server renders (see _media_modal.html.erb): a
  // positioned cell wrapping the tile and its remove ×. The tile is a
  // <button>, so the × can't be nested inside it.
  //
  // `id` and `deleteUrl` come off the create response and used to be dropped
  // on the floor here — which made a tile you had just uploaded the one tile
  // you could not remove without leaving the editor and reloading it.
  _prependBrandTile({ url, thumb, id, delete_url: deleteUrl }) {
    if (!this.hasBrandGridTarget || !url) return
    const cell = document.createElement("div")
    cell.className = "media-library-cell"

    const btn = document.createElement("button")
    btn.type = "button"
    btn.className = "media-library-item"
    btn.style.backgroundImage = `url('${thumb || url}')`
    btn.dataset.url = url
    if (id) btn.dataset.assetId = String(id)
    btn.dataset.mediaPickerTarget = "libraryItem"
    btn.dataset.action = "click->media-picker#pickLibraryItem"
    btn.setAttribute("aria-selected", "false")
    cell.appendChild(btn)

    // Only ever reachable by an admin: this path runs off the add-to-library
    // tile, which is itself admin-only, and the endpoint gates again server
    // side. Absent deleteUrl, the tile is simply not removable until reload.
    if (deleteUrl) cell.appendChild(this._brandDeleteButton(deleteUrl))

    const addTile = this.brandGridTarget.querySelector(".media-library-add")
    addTile ? addTile.after(cell) : this.brandGridTarget.prepend(cell)
  }

  _brandDeleteButton(deleteUrl) {
    const del = document.createElement("button")
    del.type = "button"
    del.className = "media-library-del"
    del.title = t("editor.remove_from_library")
    del.setAttribute("aria-label", del.title)
    del.dataset.deleteUrl = deleteUrl
    del.dataset.action = "click->media-picker#deleteBrandAsset"
    del.textContent = "\u00D7"
    return del
  }

  // Remove a brand asset from inside the picker. The affordance already
  // existed on Settings → Brand; the grid a creator is actually looking at
  // when they decide an image was a mistake is this one.
  //
  // The endpoint answers JSON here rather than redirecting, because this runs
  // inside a modal over an editor that may hold unsaved cards — a redirect
  // would navigate them away to make a thumbnail disappear.
  async deleteBrandAsset(event) {
    // The × sits ON the tile, and the tile is a picker button. Without this
    // the removal would also select the image it is removing.
    event.preventDefault()
    event.stopPropagation()

    const del  = event.currentTarget
    const cell = del.closest(".media-library-cell")
    const url  = del.dataset.deleteUrl
    if (!url || del.disabled) return
    if (!window.confirm(t("editor.library_remove_confirm"))) return

    del.disabled = true
    try {
      const res = await fetch(url, {
        method: "DELETE",
        headers: {
          "Accept": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || ""
        }
      })
      const data = await res.json().catch(() => ({}))
      if (!data.ok) {
        del.disabled = false
        this._brandStatus(data.error || t("editor.library_remove_failed"))
        return
      }
      this._brandStatus("")
      this._forgetPickIfRemoved(cell)
      cell?.remove()
    } catch (_) {
      del.disabled = false
      this._brandStatus(t("editor.library_remove_failed"))
    }
  }

  // Apply is armed by a pending URL, not by what is on screen. Delete the tile
  // that armed it and Apply would still be lit, pointing at a blob that has
  // just been purged — the card would take a 404 for an image.
  _forgetPickIfRemoved(cell) {
    const tile = cell?.querySelector(".media-library-item")
    if (!tile || this._pendingUrl !== tile.dataset.url) return
    this._pendingUrl       = null
    this._pendingCredit    = ""
    this._pendingCreditUrl = ""
    this._setApplyEnabled(false)
  }

  _brandStatus(message) {
    if (this.hasBrandStatusTarget) this.brandStatusTarget.textContent = message
  }

  clearImage() {
    if (this._mode === "background") {
      this._setVertoBackground("")
      this.close()
      return
    }
    if (this._mode === "consent") {
      this.dispatch("consentImage", { detail: { url: "", credit: "", creditUrl: "" } })
      this.close()
      return
    }
    if (!this._activeCard) return
    if (this._mode === "tapOption") {
      this._setTapOptionImage(this._activeCard, this._optionIndex, "")
      this._notifyDirty()
      this.close()
      return
    }
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

  // Sets (or clears) ONE tap-card statement's image — mirrors _setCardImage
  // but writes into the option_images array at `index` and repaints only
  // that one card slot, not the whole card. Targets .rotate-card-media when
  // present (the server-rendered markup); falls back to the .rotate-card
  // itself for type_panel_controller.js's client-side preview, which paints
  // its background directly on that element instead.
  _setTapOptionImage(card, index, url) {
    const images = this._parseUrls(card.dataset.cardOptionImages)
    while (images.length <= index) images.push("")
    images[index] = url || ""
    card.dataset.cardOptionImages = JSON.stringify(images)

    const rotateCard = card.querySelectorAll(".rotate-card")[index]
    if (!rotateCard) return
    const target = rotateCard.querySelector(".rotate-card-media") || rotateCard
    if (url) {
      target.style.background = `#fff url('${url.replace(/'/g, "\\'")}') center/cover no-repeat`
    } else {
      const [ a, b ] = this.constructor.TAP_OPTION_FILLS[index % this.constructor.TAP_OPTION_FILLS.length]
      target.style.background = `linear-gradient(135deg,${a},${b})`
    }
  }

  _setCardImage(card, url, credit = "", creditUrl = "", media = {}) {
    // A different picture has a different subject, so an old mobile-header
    // focal point is meaningless against it — back to centre.
    if (card) delete card.dataset.cardFocalY
    // "Animate asset" is a preference, not tied to one specific photo, so it
    // survives swapping to a different picture — cleared only when the card
    // ends up with no picture at all.
    if (card && !url) delete card.dataset.cardAnimateAsset

    card.dataset.cardImage = url || ""
    // The re-crop record rides with the picture it belongs to: stamped when
    // this apply carries one (a cropped upload, an Adjust re-crop), cleared
    // by any other change — a different photo has a different original, and
    // no record means the legacy remove-and-reupload behaviour.
    if (url && media.source) {
      card.dataset.cardImageSource = media.source
      if (media.crop) card.dataset.cardImageCrop = JSON.stringify(media.crop)
      else delete card.dataset.cardImageCrop
    } else {
      delete card.dataset.cardImageSource
      delete card.dataset.cardImageCrop
    }
    this._syncAdjustFab(card)
    card.dataset.cardImageCredit = url ? (credit || "") : ""
    card.dataset.cardImageCreditUrl = url ? (creditUrl || "") : ""
    // Picking/clearing a photo replaces any auto-populated video or pasted
    // animation on this card.
    card.dataset.cardVideo = ""
    card.dataset.cardVideoPoster = ""
    card.dataset.cardLottie = ""
    this._syncAnimateAssetClass(card)
    const left = card.querySelector(".split-left")
    if (!left) return
    left.querySelector(".split-left-video[data-card-media]")?.remove()
    left.querySelector(".card-lottie[data-card-media]")?.remove()
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

  // The "Adjust crop" fab is server-rendered on photo-capable cards and
  // shown only while the card carries a photo the crop stage can actually
  // reopen — same-origin (a stored path or data URL), because drawing a
  // cross-origin image (a Pexels pick) taints the canvas and the final
  // encode throws. Kept in sync here so a just-applied upload gets its fab
  // without waiting for the next server render.
  _syncAdjustFab(card) {
    const fab = card?.querySelector(".adjust-crop-fab")
    if (!fab) return
    const url = card.dataset.cardImage || ""
    fab.hidden = !(url.startsWith("/") || url.startsWith("data:"))
  }

  // Swap a card's left panel to an autoplaying video, mirroring the server
  // render (the autoplay-video controller handles play/pause + lazy loading).
  _setCardVideo(card, video, poster, credit = "", creditUrl = "") {
    card.dataset.cardVideo = video || ""
    card.dataset.cardVideoPoster = poster || ""
    card.dataset.cardImage = ""
    // No photo, no re-crop record — see _setCardImage.
    delete card.dataset.cardImageSource
    delete card.dataset.cardImageCrop
    this._syncAdjustFab(card)
    card.dataset.cardImageCredit = video ? (credit || "") : ""
    card.dataset.cardImageCreditUrl = video ? (creditUrl || "") : ""
    card.dataset.cardLottie = ""
    // The breathe toggle only applies to a photo or a Lottie — irrelevant
    // once the panel is a video, whose own motion is enough.
    delete card.dataset.cardAnimateAsset
    this._syncAnimateAssetClass(card)
    const left = card.querySelector(".split-left")
    if (!left) return
    left.querySelector(".split-left-img[data-card-media]")?.remove()
    left.querySelector(".split-left-video[data-card-media]")?.remove()
    left.querySelector(".card-lottie[data-card-media]")?.remove()
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

  // ── Lottie (pasted LottieFiles URL) ────────────────────────────────────
  // The URL never lands on the card: the server fetches, scrubs and stores
  // the animation JSON (CardLottieStore) and hands back a same-origin path —
  // the only form the cards sanitiser accepts for `lottie`.

  _showLottieSection(show) {
    if (this.hasLottieSectionTarget) this.lottieSectionTarget.hidden = !show
    if (show && this.hasLottieErrorTarget) this.lottieErrorTarget.hidden = true
  }

  // ── Mobile header position ────────────────────────────────────────────
  // The card image is stored whole; this records only WHICH horizontal stripe
  // of it the mobile header shows, as a background-position percentage. Nothing
  // is re-cropped, so it stays adjustable and every other surface still gets
  // the full picture.

  get _focalY() {
    const y = parseInt(this._activeCard?.dataset.cardFocalY, 10)
    return Number.isFinite(y) ? Math.min(100, Math.max(0, y)) : 50
  }

  _syncFocal() {
    const card  = this._activeCard
    const image = card?.dataset.cardImage
    const show  = this._mode === "card" && !!image
    if (this.hasFocalSectionTarget) this.focalSectionTarget.hidden = !show
    if (!show || !this.hasFocalImgTarget) return
    this.focalImgTarget.style.backgroundImage = `url('${String(image).replace(/'/g, "\\'")}')`
    this._paintFocal(this._focalY)
  }

  _paintFocal(y) {
    if (this.hasFocalImgTarget) this.focalImgTarget.style.backgroundPosition = `50% ${y}%`
  }

  // Dragging DOWN reveals more of the top of the picture, so the stored
  // percentage goes down with it — the image follows the pointer, which is what
  // "drag the image up and down" means. The frame's height is the full range.
  focalStart(event) {
    if (!this.hasFocalFrameTarget) return
    event.preventDefault()
    const frame  = this.focalFrameTarget
    const height = Math.max(frame.getBoundingClientRect().height, 1)
    const from   = this._focalY
    const startY = event.clientY
    frame.setPointerCapture?.(event.pointerId)

    const move = (e) => {
      const delta = ((e.clientY - startY) / height) * 100
      const next  = Math.round(Math.min(100, Math.max(0, from - delta)))
      this._paintFocal(next)
      this._writeFocal(next)
    }
    const stop = () => {
      frame.removeEventListener("pointermove", move)
      frame.removeEventListener("pointerup", stop)
      frame.removeEventListener("pointercancel", stop)
    }
    frame.addEventListener("pointermove", move)
    frame.addEventListener("pointerup", stop)
    frame.addEventListener("pointercancel", stop)
  }

  _writeFocal(y) {
    const card = this._activeCard
    if (!card) return
    card.dataset.cardFocalY = String(y)
    // Repaint the card's own hero at once — the custom property is what the
    // mobile and device frames crop against.
    card.querySelector(".split-left-img")?.style.setProperty("--focal-y", `${y}%`)
    this._notifyDirty()
  }

  // ── Animation backdrop ────────────────────────────────────────────────
  // A per-card colour/image behind a Lottie or a range card's reaction set,
  // overriding the Verto-wide --brand-panel. Stored as card.media_bg and read
  // back off the card row by the editor serialiser.

  get _cardAnimates() {
    const card = this._activeCard
    if (!card) return false
    return card.dataset.cardType === "range" || !!card.dataset.cardLottie
  }

  _readAnimBg() {
    try { return JSON.parse(this._activeCard?.dataset.cardMediaBg || "{}") || {} }
    catch (_) { return {} }
  }

  // One writer for the card row's dataset, the live panel style and the dirty
  // flag, so the preview and what autosave will send can never disagree.
  _writeAnimBg(bg) {
    const card = this._activeCard
    if (!card) return
    const clean = {}
    if (bg?.color) clean.color = bg.color
    if (bg?.image) clean.image = bg.image

    if (Object.keys(clean).length) card.dataset.cardMediaBg = JSON.stringify(clean)
    else delete card.dataset.cardMediaBg

    const left = card.querySelector(".split-left")
    if (left) {
      left.style.backgroundColor = clean.color || ""
      left.style.backgroundImage = clean.image ? `url('${String(clean.image).replace(/'/g, "\\'")}')` : ""
      left.style.backgroundSize     = clean.image ? "cover" : ""
      left.style.backgroundPosition = clean.image ? "center" : ""
    }
    // _notifyDirty, not dispatch("changed"): the editor root listens for
    // `input`, and there is no media-picker:changed binding to pick up — a
    // custom event here would leave the backdrop unsaved until some unrelated
    // edit happened to mark the deck dirty.
    this._notifyDirty()
  }

  _syncAnimationBg() {
    const show = this._mode === "card" && this._cardAnimates
    if (this.hasAnimBgSectionTarget) this.animBgSectionTarget.hidden = !show
    if (!show) return
    const bg = this._readAnimBg()
    if (this.hasAnimBgColorTarget && bg.color) this.animBgColorTarget.value = bg.color
    if (this.hasAnimBgClearTarget) this.animBgClearTarget.hidden = !(bg.color || bg.image)
  }

  setAnimBgColor(event) {
    this._writeAnimBg({ ...this._readAnimBg(), color: event.target.value })
    this._syncAnimationBg()
  }

  // Reuse the library/upload picker for the backdrop image by flipping the
  // mode — applyImage routes back here rather than onto the card's own media,
  // so the animation stays put and only what is behind it changes.
  openAnimBgImage(event) {
    event?.preventDefault()
    this._mode = "animBg"
    this._showMediaSwapUI(true)
    this.applyBtnTarget.hidden = false
    this._switchTabKey("library")
    this._setMedia("photos")
    this._showMediaToggle(false)
    this._showLottieSection(false)
    if (this.hasAnimBgSectionTarget) this.animBgSectionTarget.hidden = true
  }

  clearAnimBg(event) {
    event?.preventDefault()
    this._writeAnimBg({})
    if (this.hasAnimBgColorTarget) this.animBgColorTarget.value = "#2E3564"
    this._syncAnimationBg()
  }

  // Slow push-in/out loop on the card's own imagery. Meaningless for video
  // (its own motion is enough) and for range (the reaction set already
  // animates) — shown only when the panel is a photo or a Lottie.
  get _cardCanAnimateAsset() {
    const card = this._activeCard
    if (!card || card.dataset.cardType === "range") return false
    return !!(card.dataset.cardImage || card.dataset.cardLottie)
  }

  _syncAnimateAsset() {
    const show = this._mode === "card" && this._cardCanAnimateAsset
    if (this.hasAnimateAssetSectionTarget) this.animateAssetSectionTarget.hidden = !show
    if (show && this.hasAnimateAssetToggleTarget) {
      this.animateAssetToggleTarget.checked = this._activeCard.dataset.cardAnimateAsset === "true"
    }
  }

  toggleAnimateAsset(event) {
    const card = this._activeCard
    if (!card) return
    if (event.target.checked) card.dataset.cardAnimateAsset = "true"
    else delete card.dataset.cardAnimateAsset
    this._syncAnimateAssetClass(card)
    this._notifyDirty()
  }

  // One place to keep the live preview's CSS class in step with the dataset
  // — called here and from every media setter, since switching to video (or
  // clearing the card entirely) makes the toggle's state meaningless.
  _syncAnimateAssetClass(card) {
    card.querySelector(".split-left")
      ?.classList.toggle("has-asset-breathe", card.dataset.cardAnimateAsset === "true")
  }

  async applyLottie(event) {
    event?.preventDefault()
    if (this._mode !== "card" || !this._activeCard || !this.hasCardLottieUrlValue) return
    const pasted = this.lottieInputTarget.value.trim()
    if (!pasted) return

    this.lottieErrorTarget.hidden = true
    this.lottieBtnTarget.disabled = true
    try {
      const res = await fetch(this.cardLottieUrlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || ""
        },
        body: JSON.stringify({ url: pasted })
      })
      const data = await res.json().catch(() => ({}))
      if (!res.ok || !data.ok || !data.url) {
        this.lottieErrorTarget.textContent = data.error || t("editor.lottie_failed", { default: "That link doesn't look like a LottieFiles animation." })
        this.lottieErrorTarget.hidden = false
        return
      }
      this._setCardLottie(this._activeCard, data.url)
      this.lottieInputTarget.value = ""
      this._notifyDirty()
      this.close()
    } catch (_) {
      this.lottieErrorTarget.textContent = t("editor.lottie_failed", { default: "That link doesn't look like a LottieFiles animation." })
      this.lottieErrorTarget.hidden = false
    } finally {
      this.lottieBtnTarget.disabled = false
    }
  }

  // Swap a card's left panel to a looping Lottie, mirroring the server render
  // in shared/_split_left. Own class (card-lottie, NOT nps-lottie) — the
  // :has(.nps-lottie) CSS hides the Change-media CTA, which this must keep.
  _setCardLottie(card, url) {
    card.dataset.cardLottie = url || ""
    card.dataset.cardImage = ""
    // No photo, no re-crop record — see _setCardImage.
    delete card.dataset.cardImageSource
    delete card.dataset.cardImageCrop
    this._syncAdjustFab(card)
    card.dataset.cardImageCredit = ""
    card.dataset.cardImageCreditUrl = ""
    card.dataset.cardVideo = ""
    card.dataset.cardVideoPoster = ""
    // Same preference-not-tied-to-one-asset rule as a photo: survives
    // swapping to a different animation, cleared only when there's none left.
    if (!url) delete card.dataset.cardAnimateAsset
    this._syncAnimateAssetClass(card)
    const left = card.querySelector(".split-left")
    if (!left) return
    left.querySelector(".split-left-img[data-card-media]")?.remove()
    left.querySelector(".split-left-video[data-card-media]")?.remove()
    left.querySelector(".split-left-overlay[data-card-media]")?.remove()
    left.querySelector(".split-left-credit[data-card-media]")?.remove()
    let el = left.querySelector(".card-lottie[data-card-media]")
    if (!url) { el?.remove(); return }
    if (el) {
      // urlsValueChanged() re-renders the mounted player in place.
      el.dataset.lottiePlayerUrlsValue = JSON.stringify([ url ])
      return
    }
    el = document.createElement("div")
    el.className = "card-lottie"
    el.dataset.cardMedia = "true"
    el.dataset.controller = "lottie-player"
    el.dataset.lottiePlayerUrlsValue = JSON.stringify([ url ])
    el.dataset.lottiePlayerCurrentValue = "1"
    el.dataset.lottiePlayerLoopValue = "true"
    const mount = document.createElement("div")
    mount.className = "card-lottie-mount"
    mount.dataset.lottiePlayerTarget = "mount"
    el.appendChild(mount)
    left.prepend(el)
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
