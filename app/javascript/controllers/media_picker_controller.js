import { Controller } from "@hotwired/stimulus"

// Modal that lets editors attach an image to a card's left panel.
// Two sources: file upload (stored as a data URL on the card JSON) and the
// curated Verto Library (asset paths under /assets/verto-library/...).
export default class extends Controller {
  static targets = [
    "backdrop", "modal", "tab", "pane",
    "fileInput", "dropzone",
    "libraryItem", "applyBtn", "clearBtn",
    "bgThumb", "bgRemoveBtn"
  ]
  static values = { url: String }

  connect() {
    this._activeCard = null
    this._pendingUrl = null
    this._mode = "card"
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
    this._setApplyEnabled(false)
    this._switchTabKey("upload")

    const currentUrl = card.dataset.cardImage || ""
    this.clearBtnTarget.hidden = !currentUrl

    this.backdropTarget.hidden = false
    document.addEventListener("keydown", this._escListener)
  }

  // Opens the same modal but targets the Verto's backdrop instead of a card.
  openBackground(event) {
    event?.preventDefault()
    this._mode = "background"
    this._activeCard = null
    this._pendingUrl = null
    this._setApplyEnabled(false)
    this._switchTabKey("upload")
    this.clearBtnTarget.hidden = !this._currentBg()
    this.backdropTarget.hidden = false
    document.addEventListener("keydown", this._escListener)
  }

  close() {
    this.backdropTarget.hidden = true
    this._activeCard = null
    this._pendingUrl = null
    this._setApplyEnabled(false)
    this.libraryItemTargets.forEach(i => i.setAttribute("aria-selected", "false"))
    if (this.hasFileInputTarget) this.fileInputTarget.value = ""
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
    if (!file.type.startsWith("image/")) return
    const reader = new FileReader()
    reader.onload = () => {
      this._pendingUrl = reader.result
      this._setApplyEnabled(true)
    }
    reader.readAsDataURL(file)
  }

  // ── Library tab ────────────────────────────────────────
  pickLibraryItem(event) {
    const item = event.currentTarget
    this.libraryItemTargets.forEach(i => i.setAttribute("aria-selected", "false"))
    item.setAttribute("aria-selected", "true")
    this._pendingUrl = item.dataset.url
    this._setApplyEnabled(true)
  }

  // ── Apply / clear ──────────────────────────────────────
  applyImage() {
    if (!this._pendingUrl) return
    if (this._mode === "background") {
      this._setVertoBackground(this._pendingUrl)
      this.close()
      return
    }
    if (!this._activeCard) return
    this._setCardImage(this._activeCard, this._pendingUrl)
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
      await fetch(this.urlValue, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "",
        },
        body: JSON.stringify({ background_image: url || null }),
      })
    } catch (_e) {
      // best-effort; the editor stays usable even if the save fails
    }
  }

  _setCardImage(card, url) {
    card.dataset.cardImage = url || ""
    const left = card.querySelector(".split-left")
    if (!left) return
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
    } else {
      imgEl?.remove()
      ovEl?.remove()
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
}
