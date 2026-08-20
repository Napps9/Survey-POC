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
    // Scenario: mirror player_controller's interception so Preview behaves
    // exactly like the real player — Next turns the page until the book's
    // own answer page is showing.
    if (this._scenarioTurn(this.currentValue, 1)) return
    if (this.currentValue < this.cardTargets.length - 1) {
      this.currentValue++
      this._update()
    }
  }

  back() {
    if (this._scenarioTurn(this.currentValue, -1)) return
    if (this.currentValue > 0) {
      this.currentValue--
      this._update()
    }
  }

  // See player_controller.js — same pattern, duplicated because this preview
  // overlay clones the editor DOM independently rather than sharing the
  // player's controller.
  _scenarioController(idx) {
    const card = this.cardTargets[idx]
    if (!card) return null
    const el = card.querySelector('[data-controller~="scenario"]')
    if (!el) return null
    return this.application.getControllerForElementAndIdentifier(el, "scenario")
  }

  _scenarioTurn(idx, delta) {
    const ctrl = this._scenarioController(idx)
    if (!ctrl) return false
    return delta > 0 ? ctrl.next() : ctrl.back()
  }

  finish() {
    if (this._scenarioTurn(this.currentValue, 1)) return
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
      this._stripEditorChrome(clone)

      const previewCard = previewCards[i]
      // The card's TYPE has to ride along, because CSS asks about it: the
      // player puts data-card-type on .preview-card and the editor on
      // .survey-card-wrap, and every rule written against it — a scenario's
      // centred story page, a grid's third column on a wide panel — matched
      // both of those and missed this one, which is the surface whose whole
      // promise is "what the respondent sees". Set on every rebuild, not only
      // when the wrapper is created, so switching a card's type re-points it.
      previewCard.dataset.cardType = editorCard.dataset.cardType || ""
      previewCard.innerHTML = ""
      previewCard.appendChild(clone)
    })
  }

  _stripEditorChrome(clone) {
    // 1. Remove editor-only chrome elements outright. quiz-correct-block /
    //    token-award-block are the creator's Tokenomics/Quiz mode controls
    //    (relocated into the editor's sidebar tabs, or parked off-screen —
    //    either way still present in the editor DOM this clones from) and
    //    must never reach a respondent-facing view.
    clone.querySelectorAll(
      ".pick-item-delete, .tap-card-delete, .pick-add-btn, .tap-add-btn, .add-media-fab, " +
      ".split-left-design-prompt, .quiz-correct-block, .token-award-block, " +
      ".book-edit-tools, .logic-branch-block, .mark-correct, .mark-correct-grid, " +
      ".tap-card-image-btn, .slider-axis-toggle, .add-animation-fab"
    ).forEach(el => el.remove())

    // 2. The "+ Other" CTA is disabled in the editor itself (there the
    //    checkbox above it does the toggling, not the button) — re-enable it
    //    so a "Preview" respondent can actually open the free-text panel.
    clone.querySelectorAll(".other-cta-btn").forEach(el => el.removeAttribute("disabled"))

    // 3. Strip contenteditable from everything so preview is read-only.
    clone.querySelectorAll("[contenteditable]").forEach(el =>
      el.removeAttribute("contenteditable")
    )

    // 4. Drop editor-only marker attributes.
    clone.querySelectorAll("[data-card-component], [data-card-media]").forEach(el => {
      el.removeAttribute("data-card-component")
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
    // A Range card's reaction character tracks its slider (lottie-player#show
    // records the frame it renders), so a clone taken after the creator dragged
    // the editor slider would open mid-expression. Park it back on the neutral
    // middle frame, derived from the set's own length.
    clone.querySelectorAll(".nps-lottie").forEach(el => {
      let frames = 0
      try { frames = (JSON.parse(el.dataset.lottiePlayerUrlsValue || "[]") || []).length } catch (_) { /* leave as-is */ }
      if (frames) el.dataset.lottiePlayerCurrentValue = String(Math.ceil(frames / 2))
    })
    // The clone is deep, so it carries the <svg> lottie-web already rendered
    // into the editor's mount. Empty the mounts so the preview's own
    // lottie-player starts from a bare container and draws exactly one
    // animation rather than stacking a second under the cloned one.
    clone.querySelectorAll(".nps-lottie-mount, .card-lottie-mount")
         .forEach(el => el.replaceChildren())

    // 7. Drop the editor's active-card outline class if present.
    clone.classList.remove("selected")
  }
}
