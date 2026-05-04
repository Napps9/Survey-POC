import { Controller } from "@hotwired/stimulus"

// Maps actual Verto card types → badge text, badge CSS class, eyebrow label
const TYPE_META = {
  range:            { badge: "RANGE",         css: "sb-range",    label: "DRAG THE SLIDER"      },
  rating:           { badge: "RATING",         css: "sb-range",    label: "DRAG THE SLIDER"      },
  multiple_choice:  { badge: "PICK ONE",       css: "sb-range",    label: "CHOOSE ONE"           },
  select_many:      { badge: "SELECT MANY",    css: "sb-range",    label: "CHOOSE ALL THAT APPLY" },
  yes_no:           { badge: "YES / NO",       css: "sb-range",    label: "CHOOSE ONE"           },
  select_one_grid:  { badge: "IMAGE GRID",     css: "sb-choice",   label: "CHOOSE ONE"           },
  select_many_grid: { badge: "IMAGE GRID",     css: "sb-choice",   label: "CHOOSE ALL THAT APPLY" },
  tap_card:         { badge: "SWIPE",          css: "sb-swipe",    label: "SWIPE TO RESPOND"     },
  open_ended:       { badge: "OPEN TEXT",      css: "sb-text",     label: "TYPE YOUR ANSWER"     },
  static_page:      { badge: "ACTIVITY",       css: "sb-activity", label: "COMPLETE THE TASK"    },
  welcome_card:     { badge: "WELCOME CARD",   css: "sb-welcome",  label: ""                     },
}

// Card type → icon for the left panel placeholder
const TYPE_ICON = {
  tap_card:  "↔",
  open_ended: "✎",
}

export default class extends Controller {
  static targets = [
    "card", "panelEmpty", "typeList", "panelFooter",
    "panelCardName", "panelHint", "typeOpt", "toast", "toastMsg", "cardCount"
  ]

  activeCardEl = null
  pendingType  = null

  selectCard(event) {
    // Don't trigger if they clicked the delete button
    if (event.target.closest("button[data-action*='deleteCard']")) return

    const card = event.currentTarget
    this.cardTargets.forEach(c => {
      c.style.borderColor = "transparent"
      c.style.boxShadow = "none"
    })
    card.style.borderColor = "#FF1E6F"
    card.style.boxShadow = "0 0 0 2px rgba(255,30,111,0.2)"
    this.activeCardEl = card

    const cardType = card.dataset.cardType
    const cardNum  = card.dataset.cardNum
    this.pendingType = cardType

    const meta = TYPE_META[cardType]
    const badgeText = meta ? meta.badge : cardType
    this.panelCardNameTarget.textContent = `Card ${cardNum} · ${badgeText}`
    this.panelHintTarget.textContent     = "Choose an answer format below."

    this.panelEmptyTarget.style.display  = "none"
    this.typeListTarget.style.display    = "flex"
    this.panelFooterTarget.style.display = "flex"

    this.typeOptTargets.forEach(o => o.classList.toggle("active", o.dataset.type === cardType))
  }

  setType(event) {
    const type = event.currentTarget.dataset.type
    this.pendingType = type
    this.typeOptTargets.forEach(o => o.classList.toggle("active", o.dataset.type === type))
  }

  applyType() {
    if (!this.activeCardEl || !this.pendingType) return
    this._applyToCard(this.activeCardEl, this.pendingType)
    this._toast(`Answer type updated to ${TYPE_META[this.pendingType]?.badge || this.pendingType}`)
  }

  applyAll() {
    if (!this.pendingType) return
    this.cardTargets.forEach(card => this._applyToCard(card, this.pendingType))
    this._toast(`Applied to all ${this.cardTargets.length} cards`)
  }

  deleteCard(event) {
    event.stopPropagation()
    const card = event.currentTarget.closest("[data-type-panel-target='card']")
    if (!card) return
    card.remove()
    if (card === this.activeCardEl) {
      this.activeCardEl = null
      this.panelEmptyTarget.style.display  = ""
      this.typeListTarget.style.display    = "none"
      this.panelFooterTarget.style.display = "none"
    }
    this._updateCount()
  }

  _applyToCard(card, type) {
    const meta = TYPE_META[type]
    if (!meta) return

    // Update badge
    const badge = card.querySelector(".s-badge")
    if (badge) { badge.textContent = meta.badge; badge.className = `s-badge ${meta.css}` }

    // Update eyebrow label
    const eyebrow = card.querySelector(".q-eyebrow")
    if (eyebrow && meta.label) eyebrow.textContent = meta.label

    // Update left panel icon for dark-left types
    const darkLeft = card.querySelector(".split-left-dark")
    if (darkLeft) {
      const iconEl = darkLeft.querySelector("[style*='font-size:36px']") ||
                     darkLeft.querySelector("div > div")
      if (iconEl && TYPE_ICON[type]) iconEl.textContent = TYPE_ICON[type]
    }

    card.dataset.cardType = type

    if (card === this.activeCardEl) {
      const num = card.dataset.cardNum
      this.panelCardNameTarget.textContent = `Card ${num} · ${meta.badge}`
      this.typeOptTargets.forEach(o => o.classList.toggle("active", o.dataset.type === type))
    }
  }

  _updateCount() {
    if (!this.hasCardCountTarget) return
    const n = this.cardTargets.length
    this.cardCountTarget.textContent = `${n} card${n !== 1 ? "s" : ""}`
  }

  _toast(msg) {
    this.toastMsgTarget.textContent = msg
    this.toastTarget.classList.add("show")
    setTimeout(() => this.toastTarget.classList.remove("show"), 2200)
  }
}
