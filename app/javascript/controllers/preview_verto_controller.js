import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "overlay", "card", "backBtn", "nextBtn",
    "finishBtn", "thankyou", "returnBtn", "editBtn", "progress"
  ]
  static values = { current: { type: Number, default: 0 } }

  open() {
    this._syncPreviewCards()
    this.overlayTarget.classList.remove("hidden")
    this.overlayTarget.classList.add("flex")
    this.currentValue = 0
    this.thankyouTarget.classList.remove("active")
    this._update()
  }

  close() {
    this.overlayTarget.classList.add("hidden")
    this.overlayTarget.classList.remove("flex")
  }

  next() {
    if (this.currentValue < this.cardTargets.length - 1) {
      this.currentValue++
      this._update()
    }
  }

  back() {
    if (this.currentValue > 0) {
      this.currentValue--
      this._update()
    }
  }

  finish() {
    this.cardTargets.forEach(c => c.classList.remove("active"))
    this.thankyouTarget.classList.add("active")
    this.backBtnTarget.classList.add("hidden")
    this.nextBtnTarget.classList.add("hidden")
    this.finishBtnTarget.classList.add("hidden")
    if (this.hasEditBtnTarget) this.editBtnTarget.classList.add("hidden")
    this.returnBtnTarget.classList.remove("hidden")
    this.progressTarget.textContent = ""
  }

  returnToDesign() {
    this.close()
    // Reset so next open() starts clean
    this.thankyouTarget.classList.remove("active")
    this.returnBtnTarget.classList.add("hidden")
    this._update()
  }

  // Close the preview and drop the user back into the editor with the
  // card they were just looking at selected (so the type panel shows
  // that card's options).
  edit() {
    const idx = this.currentValue
    this.close()
    this.thankyouTarget.classList.remove("active")
    this.returnBtnTarget.classList.add("hidden")
    this._update()
    const editorCards = document.querySelectorAll('[data-type-panel-target="card"]')
    const target = editorCards[idx]
    if (!target) return
    target.scrollIntoView({ behavior: "smooth", block: "center" })
    target.click()
  }

  _update() {
    const total = this.cardTargets.length
    const idx   = this.currentValue

    this.cardTargets.forEach((c, i) =>
      c.classList.toggle("active", i === idx))

    this.progressTarget.textContent = `Card ${idx + 1} of ${total}`

    // Back: invisible on first card so layout doesn't shift
    this.backBtnTarget.classList.remove("hidden")
    this.backBtnTarget.classList.toggle("invisible", idx === 0)
    this.backBtnTarget.classList.remove("invisible-off")

    // Edit: always visible while previewing, hidden on the thank-you screen
    if (this.hasEditBtnTarget) this.editBtnTarget.classList.remove("hidden")

    // Next vs Finish
    const isLast = idx === total - 1
    this.nextBtnTarget.classList.toggle("hidden", isLast)
    this.finishBtnTarget.classList.toggle("hidden", !isLast)
    this.returnBtnTarget.classList.add("hidden")
  }

  // Rebuild preview cards from the editor's live DOM. The editor card
  // markup IS the source of truth — autosave reads from it too. We
  // deep-clone each editor `.split-card`, strip the editor-only chrome
  // (contenteditable, delete/add buttons, the "Add media" FAB, the
  // card-editor controller binding), and drop it into the matching
  // `.preview-card` wrapper. Stimulus's MutationObserver rebinds the
  // picker / tap-stack / slider / rating controllers automatically.
  _syncPreviewCards() {
    const editorCards = Array.from(
      document.querySelectorAll('[data-type-panel-target="card"]')
    )
    const previewBody = this.element.querySelector(".preview-body")
    if (!previewBody) return

    let previewCards = Array.from(previewBody.querySelectorAll(".preview-card"))

    // Reconcile count — add wrappers for new cards, remove trailing
    // wrappers if the editor has fewer cards now.
    while (previewCards.length < editorCards.length) {
      const wrap = document.createElement("div")
      wrap.className = "preview-card"
      wrap.setAttribute("data-preview-verto-target", "card")
      // Insert before the thank-you screen so it stays at the end.
      const thankyou = previewBody.querySelector(".preview-thankyou")
      previewBody.insertBefore(wrap, thankyou)
      previewCards.push(wrap)
    }
    while (previewCards.length > editorCards.length) {
      const extra = previewCards.pop()
      extra.remove()
    }

    editorCards.forEach((editorCard, i) => {
      const splitCard = editorCard.querySelector(".split-card")
      if (!splitCard) return

      const clone = splitCard.cloneNode(true)
      this._stripEditorChrome(clone, editorCard)

      const previewCard = previewCards[i]
      previewCard.innerHTML = ""
      previewCard.appendChild(clone)
    })
  }

  _stripEditorChrome(clone, editorCard) {
    // 1. Remove editor-only chrome elements outright.
    clone.querySelectorAll(
      ".pick-item-delete, .tap-card-delete, .pick-add-btn, .tap-add-btn, .add-media-fab"
    ).forEach(el => el.remove())

    // 2. Hide illustration when the card has an image — preview shows
    //    image OR illustration, not both (see _split_left.html.erb).
    const hasImage = (editorCard.dataset.cardImage || "").trim().length > 0
    if (hasImage) {
      clone.querySelectorAll(".split-left-illustration").forEach(el => el.remove())
    }

    // 3. Strip contenteditable from everything so preview is read-only.
    clone.querySelectorAll("[contenteditable]").forEach(el =>
      el.removeAttribute("contenteditable")
    )

    // 4. Drop editor-only marker attributes.
    clone.querySelectorAll("[data-card-component], [data-card-illustration], [data-card-media]").forEach(el => {
      el.removeAttribute("data-card-component")
      el.removeAttribute("data-card-illustration")
      el.removeAttribute("data-card-media")
    })

    // 5. Strip the "card-editor" Stimulus controller binding — only
    //    "picker" / "tap-stack" should survive on the preview clone.
    clone.querySelectorAll("[data-controller]").forEach(el => {
      const cleaned = el.getAttribute("data-controller")
        .split(/\s+/).filter(c => c && c !== "card-editor").join(" ")
      el.setAttribute("data-controller", cleaned)
    })

    // 6. Reset interactive state so each open() starts clean.
    clone.querySelectorAll('[data-picker-target="item"]').forEach(el => {
      el.setAttribute("data-selected", "false")
      el.classList.remove("selected", "active")
    })
    clone.querySelectorAll(".rotate-card").forEach(el => {
      // Drop inline transform from mid-swipe state but keep the gradient
      // background that the ERB partial sets via style="background:…".
      const bg = el.style.background || el.style.backgroundImage
      el.removeAttribute("style")
      if (bg) el.style.background = bg
    })

    // 7. Drop the editor's active-card outline class if present.
    clone.classList.remove("selected")
  }
}
