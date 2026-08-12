import { Controller } from "@hotwired/stimulus"
import { hasEmailFormatting } from "lib/rich_text"

// The Comms email builder: the survey editor's grammar applied to an email
// document. The DOM is the document — every serializable non-text field
// lives as data-block-* on the block wrap (data-setting-* on the paper), and
// serialize() reads the live DOM in order. Every edit funnels into
// markDirty(): a bubbled `input` from the contenteditable bodies and
// inspector fields, or rich-text:changed / media-picker:commsImage events on
// the root. Autosave PATCHes the whole document, debounced 1.5s, with the
// survey editor's generation guard (an in-flight save must not mark edits
// typed during the request as clean) and its keepalive unload flush.
//
// Undo is structural-only (block add/remove/move keep the detached node),
// same scope as the survey editor; text edits belong to the browser's own
// contenteditable undo.
export default class extends Controller {
  static targets = ["title", "status", "undoBtn", "canvas", "paper", "slot", "block",
                    "panelTitle", "panelEmpty", "controls", "blockView", "designView",
                    "audienceView", "sendView", "addMenu", "previewOverlay", "previewFrame"]
  static values = { url: String, previewUrl: String, locked: Boolean }

  static MAX_UNDO = 25

  connect() {
    this._undo = []
    this._dirty = false
    this._editGen = 0
    this._flush = () => this.flushSave()
    window.addEventListener("pagehide", this._flush)
    window.addEventListener("beforeunload", this._flush)
    document.addEventListener("visibilitychange", this._flush)
    this._keydown = (e) => this._onKeydown(e)
    document.addEventListener("keydown", this._keydown)
    this._seedInspectorDefaults()
  }

  disconnect() {
    window.removeEventListener("pagehide", this._flush)
    window.removeEventListener("beforeunload", this._flush)
    document.removeEventListener("visibilitychange", this._flush)
    document.removeEventListener("keydown", this._keydown)
    clearTimeout(this._saveTimer)
  }

  // ── Autosave ──────────────────────────────────────────────────────────────

  markDirty() {
    if (this.lockedValue) return
    this.flash("Unsaved changes", "text-light-yellow")
    this._dirty = true
    this._editGen += 1
    clearTimeout(this._saveTimer)
    this._saveTimer = setTimeout(() => this._doSave(), 1500)
  }

  async _doSave() {
    if (!this.hasUrlValue || !this.urlValue || this.lockedValue) return
    try {
      const gen = this._editGen
      const res = await fetch(this.urlValue, {
        method: "PATCH",
        headers: this._headers(),
        body: JSON.stringify(this.serialize())
      })
      if (!res.ok) throw new Error(`HTTP ${res.status}`)
      const json = await res.json()
      if (gen === this._editGen) this._dirty = false
      const time = new Date(json.updated_at).toLocaleTimeString()
      if (Array.isArray(json.warnings) && json.warnings.length) {
        this.flash(`Saved ${time} — ${json.warnings[0]}`, "text-light-yellow")
      } else {
        this.flash(`Saved ${time}`, "text-aquamarine")
      }
    } catch (err) {
      this.flash(`Save failed: ${err.message}`, "text-hot-pink")
    }
  }

  // Same reasoning as the survey editor: keepalive fetch (sendBeacon can't
  // carry a PATCH + CSRF header), best-effort on the unload path.
  flushSave() {
    if (!this._dirty || this.lockedValue) return
    if (!this.hasUrlValue || !this.urlValue) return
    clearTimeout(this._saveTimer)
    this._dirty = false
    try {
      fetch(this.urlValue, {
        method: "PATCH", keepalive: true, headers: this._headers(),
        body: JSON.stringify(this.serialize())
      })
    } catch (_) { /* unload path — nothing more we can do */ }
  }

  _headers() {
    return {
      "Content-Type": "application/json",
      "Accept": "application/json",
      "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || ""
    }
  }

  flash(text, klass) {
    if (!this.hasStatusTarget) return
    this.statusTarget.textContent = text
    this.statusTarget.className = `text-xs ${klass}`
  }

  // ── Serialization: the DOM is the document ────────────────────────────────

  serialize() {
    const p = this.paperTarget.dataset
    const settings = {
      backgroundColor: p.settingBackgroundColor,
      contentBackgroundColor: p.settingContentBackgroundColor,
      textColor: p.settingTextColor,
      linkColor: p.settingLinkColor,
      fontFamily: p.settingFontFamily,
      contentWidth: parseInt(p.settingContentWidth, 10) || 600,
      headingWeight: parseInt(p.settingHeadingWeight, 10) || 700,
      headingTransform: p.settingHeadingTransform === "uppercase" ? "uppercase" : "none",
      headingLetterSpacing: parseInt(p.settingHeadingLetterSpacing, 10) || 0,
      buttonRadius: parseInt(p.settingButtonRadius, 10) || 8
    }
    const blocks = this.slotTargets.map((slot) => this._serializeBlock(slot)).filter(Boolean)
    return { title: this._titleText(), design: { version: 1, settings, blocks } }
  }

  _serializeBlock(slot) {
    const el = slot.querySelector(".comms-block")
    if (!el) return null
    const d = el.dataset
    const base = { id: d.blockId, type: d.blockType }
    switch (d.blockType) {
      case "heading": case "text": {
        const body = el.querySelector("[data-block-field='text']")
        const block = { ...base, text: this._plain(body), align: d.blockAlign || "left",
                        color: d.blockColor || "#0F172A" }
        if (d.blockType === "heading") block.level = parseInt(d.blockLevel, 10) || 2
        if (body && hasEmailFormatting(body)) block.text_html = body.innerHTML
        return block
      }
      case "button": {
        const label = el.querySelector("[data-block-field='text']")
        return { ...base, text: this._plain(label), href: d.blockHref || "",
                 align: d.blockAlign || "left",
                 backgroundColor: d.blockBackgroundColor || "#01EACB",
                 textColor: d.blockTextColor || "#FFFFFF",
                 radius: parseInt(d.blockRadius, 10) || 0 }
      }
      case "image":
        return { ...base, src: d.blockSrc || "", alt: d.blockAlt || "",
                 href: d.blockHref || "", widthPct: parseInt(d.blockWidthPct, 10) || 100,
                 align: d.blockAlign || "center" }
      case "divider":
        return { ...base, color: d.blockColor || "#E2E8F0" }
      case "spacer":
        return { ...base, height: parseInt(d.blockHeight, 10) || 24 }
      default:
        return null
    }
  }

  _plain(el) {
    if (!el) return ""
    return el.innerText.replace(/ /g, " ").replace(/\n+$/, "")
  }

  // ── Title pill ────────────────────────────────────────────────────────────

  _titleText() {
    return this.hasTitleTarget ? this.titleTarget.textContent.trim() : ""
  }

  renameCampaign() { this.markDirty() }

  commitRename(event) {
    event.preventDefault()
    this.titleTarget.blur()
  }

  restoreRenameIfBlank() {
    if (!this._titleText()) this.titleTarget.textContent = "Untitled campaign"
  }

  // ── Selection + inspector ─────────────────────────────────────────────────

  selectBlock(event) {
    const block = event.currentTarget.closest(".comms-block") || event.target.closest(".comms-block")
    if (!block) return
    this.blockTargets.forEach((b) => b.classList.toggle("is-selected", b === block))
    this._selected = block
    this.element.classList.add("is-panel-open")
    this.closeDesign()
    this._populateInspector(block)
  }

  _populateInspector(block) {
    const type = block.dataset.blockType
    if (this.hasPanelTitleTarget) this.panelTitleTarget.textContent = type.charAt(0).toUpperCase() + type.slice(1)
    if (this.hasPanelEmptyTarget) this.panelEmptyTarget.style.display = "none"
    this.controlsTargets.forEach((section) => {
      const match = section.dataset.blockControls === type
      section.hidden = !match
      if (!match) return
      section.querySelectorAll("[data-field]").forEach((input) => {
        const value = block.dataset[this._dsKey(input.dataset.field)]
        if (value !== undefined) input.value = value
      })
    })
  }

  _dsKey(field) {
    return "block" + field.charAt(0).toUpperCase() + field.slice(1)
  }

  applyField(event) {
    const block = this._selected
    if (!block || this.lockedValue) return
    const field = event.currentTarget.dataset.field
    block.dataset[this._dsKey(field)] = event.currentTarget.value
    this._repaintBlock(block)
    this.markDirty()
  }

  applySetting(event) {
    if (this.lockedValue) return
    const key = event.currentTarget.dataset.setting
    const ds = "setting" + key.charAt(0).toUpperCase() + key.slice(1)
    this.paperTarget.dataset[ds] = event.currentTarget.value
    this._repaintCanvas()
    this.markDirty()
  }

  _repaintCanvas() {
    const d = this.paperTarget.dataset
    this.canvasTarget.style.background = d.settingBackgroundColor
    this.paperTarget.style.background = d.settingContentBackgroundColor
    this.paperTarget.style.maxWidth = `${d.settingContentWidth}px`
    this.paperTarget.style.fontFamily = d.settingFontFamily
    this.blockTargets.forEach((b) => {
      if (b.dataset.blockType === "heading") this._repaintBlock(b)
    })
  }

  _repaintBlock(block) {
    const d = block.dataset
    const body = block.querySelector("[data-block-field='text']")
    switch (d.blockType) {
      case "heading": {
        let h = block.querySelector("h1,h2,h3")
        const wanted = `h${parseInt(d.blockLevel, 10) || 2}`
        if (h && h.tagName.toLowerCase() !== wanted) {
          const next = document.createElement(wanted)
          for (const attr of h.attributes) next.setAttribute(attr.name, attr.value)
          while (h.firstChild) next.appendChild(h.firstChild)
          h.replaceWith(next)
          h = next
        }
        if (!h) return
        const p = this.paperTarget.dataset
        const size = { 1: 28, 2: 22, 3: 18 }[parseInt(d.blockLevel, 10) || 2]
        h.style.cssText = `margin:0;font-weight:${p.settingHeadingWeight};font-size:${size}px;` +
          `line-height:1.3;color:${d.blockColor};text-align:${d.blockAlign};` +
          `text-transform:${p.settingHeadingTransform};letter-spacing:${p.settingHeadingLetterSpacing}px;`
        break
      }
      case "text":
        if (body) {
          body.style.color = d.blockColor
          body.style.textAlign = d.blockAlign
        }
        break
      case "button": {
        const span = block.querySelector(".comms-btn")
        if (span) {
          span.style.background = d.blockBackgroundColor
          span.style.color = d.blockTextColor
          span.style.borderRadius = `${d.blockRadius}px`
          span.parentElement.style.textAlign = d.blockAlign
        }
        break
      }
      case "image": {
        const img = block.querySelector("img.comms-img")
        if (img) {
          img.style.width = `${d.blockWidthPct}%`
          img.alt = d.blockAlt || ""
          if (d.blockSrc && img.getAttribute("src") !== d.blockSrc) img.src = d.blockSrc
          img.parentElement.style.textAlign = d.blockAlign
        } else if (d.blockSrc) {
          // Empty-state button becomes a real image once a src arrives.
          const bodyWrap = block.querySelector(".comms-block-body")
          bodyWrap.innerHTML = ""
          const wrap = document.createElement("div")
          wrap.style.textAlign = d.blockAlign || "center"
          const image = document.createElement("img")
          image.className = "comms-img"
          image.src = d.blockSrc
          image.alt = d.blockAlt || ""
          image.style.width = `${d.blockWidthPct || 100}%`
          image.dataset.action = "click->media-picker#openComms"
          wrap.appendChild(image)
          bodyWrap.appendChild(wrap)
        }
        break
      }
      case "divider": {
        const line = block.querySelector(".comms-div")
        if (line) line.style.borderTop = `1px solid ${d.blockColor}`
        break
      }
      case "spacer": {
        const box = block.querySelector(".comms-spacer")
        if (box) {
          box.style.height = `${d.blockHeight}px`
          const label = box.querySelector("span")
          if (label) label.textContent = `${d.blockHeight}px`
        }
        break
      }
    }
  }

  // The media picker's comms mode reports the stored image URL here.
  applyImage(event) {
    const block = this._selected
    if (!block || block.dataset.blockType !== "image") return
    block.dataset.blockSrc = event.detail.url
    this._repaintBlock(block)
    this.markDirty()
  }

  // ── Design takeover ───────────────────────────────────────────────────────

  openDesign() {
    this._openTakeover("designView")
    this.designViewTarget.querySelectorAll("[data-setting]").forEach((input) => {
      const key = input.dataset.setting
      const value = this.paperTarget.dataset["setting" + key.charAt(0).toUpperCase() + key.slice(1)]
      if (value !== undefined) input.value = value
    })
  }

  openAudience() { this._openTakeover("audienceView") }
  closeAudience() { this._closeTakeovers() }
  openSend() { this._openTakeover("sendView") }
  closeSend() { this._closeTakeovers() }

  _openTakeover(name) {
    if (!this[`has${name.charAt(0).toUpperCase() + name.slice(1)}Target`]) return
    this.element.classList.add("is-panel-open")
    this.blockViewTarget.hidden = true
    if (this.hasDesignViewTarget) this.designViewTarget.hidden = true
    if (this.hasAudienceViewTarget) this.audienceViewTarget.hidden = true
    if (this.hasSendViewTarget) this.sendViewTarget.hidden = true
    this[`${name}Target`].hidden = false
  }

  _closeTakeovers() {
    if (this.hasDesignViewTarget) this.designViewTarget.hidden = true
    if (this.hasAudienceViewTarget) this.audienceViewTarget.hidden = true
    if (this.hasSendViewTarget) this.sendViewTarget.hidden = true
    this.blockViewTarget.hidden = false
  }

  closeDesign() { this._closeTakeovers() }

  // ── Structure: add / duplicate / move / delete + undo ─────────────────────

  toggleAddMenu() {
    this.addMenuTarget.hidden = !this.addMenuTarget.hidden
  }

  addBlock(event) {
    const type = event.currentTarget.dataset.type
    this.addMenuTarget.hidden = true
    const template = document.querySelector(`template[data-comms-template="${type}"]`)
    if (!template) return
    const fragment = template.content.cloneNode(true)
    const slot = fragment.querySelector(".comms-block-slot")
    const block = slot.querySelector(".comms-block")
    block.dataset.blockId = `b_${Math.random().toString(36).slice(2, 10)}`
    const anchor = this._selected?.closest(".comms-block-slot")
    if (anchor) anchor.after(slot)
    else this.paperTarget.insertBefore(slot, this.paperTarget.querySelector(".comms-add-row"))
    this._recordUndo({ type: "insert", slot })
    this.selectBlock({ currentTarget: block, target: block })
    this.markDirty()
  }

  duplicateBlock(event) {
    const slot = event.currentTarget.closest(".comms-block-slot")
    const copy = slot.cloneNode(true)
    const block = copy.querySelector(".comms-block")
    block.classList.remove("is-selected")
    block.dataset.blockId = `b_${Math.random().toString(36).slice(2, 10)}`
    slot.after(copy)
    this._recordUndo({ type: "insert", slot: copy })
    this.markDirty()
  }

  moveUp(event) { this._move(event, -1) }
  moveDown(event) { this._move(event, 1) }

  _move(event, dir) {
    const slot = event.currentTarget.closest(".comms-block-slot")
    const sibling = dir < 0 ? slot.previousElementSibling : slot.nextElementSibling
    if (!sibling || !sibling.classList.contains("comms-block-slot")) return
    dir < 0 ? sibling.before(slot) : sibling.after(slot)
    this._recordUndo({ type: "move", slot, dir })
    this.markDirty()
  }

  deleteBlock(event) {
    const btn = event.currentTarget
    if (!btn.classList.contains("is-armed")) {
      btn.classList.add("is-armed")
      btn.textContent = "Sure?"
      this._disarmTimer = setTimeout(() => this._disarm(btn), 3000)
      return
    }
    clearTimeout(this._disarmTimer)
    const slot = btn.closest(".comms-block-slot")
    this._disarm(btn)
    // Keep the still-attached node's position so undo re-inserts it exactly.
    this._recordUndo({ type: "delete", slot, anchor: slot.previousElementSibling, parent: slot.parentElement })
    slot.remove()
    if (this._selected && !this.element.contains(this._selected)) this._clearSelection()
    this.markDirty()
  }

  _disarm(btn) {
    btn.classList.remove("is-armed")
    btn.textContent = btn.dataset.restingLabel || "✕"
  }

  _clearSelection() {
    this._selected = null
    if (this.hasPanelEmptyTarget) this.panelEmptyTarget.style.display = ""
    if (this.hasPanelTitleTarget) this.panelTitleTarget.textContent = "—"
    this.controlsTargets.forEach((section) => { section.hidden = true })
  }

  _recordUndo(entry) {
    this._undo.push(entry)
    if (this._undo.length > this.constructor.MAX_UNDO) this._undo.shift()
    if (this.hasUndoBtnTarget) this.undoBtnTarget.disabled = false
  }

  undo() {
    const entry = this._undo.pop()
    if (!entry) return
    switch (entry.type) {
      case "insert":
        entry.slot.remove()
        if (this._selected && !this.element.contains(this._selected)) this._clearSelection()
        break
      case "delete":
        if (entry.anchor && entry.parent.contains(entry.anchor)) entry.anchor.after(entry.slot)
        else entry.parent.prepend(entry.slot)
        break
      case "move": {
        const slot = entry.slot
        const sibling = entry.dir < 0 ? slot.nextElementSibling : slot.previousElementSibling
        if (sibling && sibling.classList.contains("comms-block-slot")) {
          entry.dir < 0 ? sibling.after(slot) : sibling.before(slot)
        }
        break
      }
    }
    if (this.hasUndoBtnTarget) this.undoBtnTarget.disabled = this._undo.length === 0
    this.markDirty()
  }

  _onKeydown(e) {
    if (!(e.metaKey || e.ctrlKey) || e.key.toLowerCase() !== "z" || e.shiftKey) return
    const t = e.target
    if (t.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(t.tagName)) return
    if (this.lockedValue || this._undo.length === 0) return
    e.preventDefault()
    this.undo()
  }

  // ── Compiled preview ──────────────────────────────────────────────────────

  async openPreview() {
    clearTimeout(this._saveTimer)
    if (this._dirty) await this._doSave()
    this.previewFrameTarget.src = `${this.previewUrlValue}?ts=${Date.now()}`
    this.previewOverlayTarget.hidden = false
  }

  closePreview() {
    this.previewOverlayTarget.hidden = true
    this.previewFrameTarget.src = "about:blank"
  }

  // Inspector inputs start unbound to any block; seed nothing until a
  // selection exists (the empty-state hint stays visible).
  _seedInspectorDefaults() {}
}
