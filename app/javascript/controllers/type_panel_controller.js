import { Controller } from "@hotwired/stimulus"

const TYPE_META = {
  range:            { badge: "RANGE",         css: "sb-range",    label: "DRAG THE SLIDER"       },
  rating:           { badge: "RATING",         css: "sb-range",    label: "DRAG THE SLIDER"       },
  multiple_choice:  { badge: "PICK ONE",       css: "sb-range",    label: "CHOOSE ONE"            },
  select_many:      { badge: "SELECT MANY",    css: "sb-range",    label: "CHOOSE ALL THAT APPLY" },
  yes_no:           { badge: "YES / NO",       css: "sb-range",    label: "CHOOSE ONE"            },
  select_one_grid:  { badge: "IMAGE GRID",     css: "sb-choice",   label: "CHOOSE ONE"            },
  select_many_grid: { badge: "IMAGE GRID",     css: "sb-choice",   label: "CHOOSE ALL THAT APPLY" },
  tap_card:         { badge: "SWIPE",          css: "sb-swipe",    label: "SWIPE TO RESPOND"      },
  open_ended:       { badge: "OPEN TEXT",      css: "sb-text",     label: "TYPE YOUR ANSWER"      },
  static_page:      { badge: "ACTIVITY",       css: "sb-activity", label: "COMPLETE THE TASK"     },
  welcome_card:     { badge: "WELCOME CARD",   css: "sb-welcome",  label: ""                      },
}

// Ordered list of valid alternative types per source type, with relevance score.
// Score 100 = the AI's chosen type (primary fit).
// Lower scores = valid but less ideal substitutes per the Do's & Don'ts rules.
const COMPATIBILITY = {
  multiple_choice: [
    { type: "multiple_choice",  score: 100, note: "Best fit — discrete single-pick list" },
    { type: "select_many",      score: 85,  note: "Same UI, allow multiple picks instead" },
    { type: "select_one_grid",  score: 70,  note: "Grid layout — works with even option counts" },
    { type: "yes_no",           score: 55,  note: "Simplify to a binary gate" },
    { type: "range",            score: 40,  note: "Use only if answer is scale-like" },
  ],
  select_many: [
    { type: "select_many",      score: 100, note: "Best fit — multi-pick list" },
    { type: "multiple_choice",  score: 80,  note: "Constrain to a single pick" },
    { type: "select_many_grid", score: 70,  note: "Grid layout for multi-pick" },
    { type: "select_one_grid",  score: 45,  note: "Grid layout, single pick only" },
  ],
  select_one_grid: [
    { type: "select_one_grid",  score: 100, note: "Best fit — image grid, single pick" },
    { type: "select_many_grid", score: 80,  note: "Allow multiple picks in the grid" },
    { type: "multiple_choice",  score: 65,  note: "Flatten to a list instead" },
    { type: "select_many",      score: 45,  note: "Flat list with multi-pick" },
  ],
  select_many_grid: [
    { type: "select_many_grid", score: 100, note: "Best fit — image grid, multi-pick" },
    { type: "select_one_grid",  score: 80,  note: "Constrain grid to single pick" },
    { type: "select_many",      score: 65,  note: "Flatten to a multi-pick list" },
    { type: "multiple_choice",  score: 45,  note: "Flat list, single pick only" },
  ],
  tap_card: [
    { type: "tap_card",         score: 100, note: "Best fit — rapid swipe reactions" },
    { type: "range",            score: 60,  note: "Replace with a single agree/disagree scale" },
    { type: "rating",           score: 55,  note: "Icon-based scale as alternative" },
    { type: "multiple_choice",  score: 40,  note: "Simplify to a static choice list" },
  ],
  range: [
    { type: "range",            score: 100, note: "Best fit — animated qualitative scale" },
    { type: "rating",           score: 85,  note: "Icon-based scale — similar feel" },
    { type: "tap_card",         score: 50,  note: "Replace with sequential swipe cards" },
    { type: "yes_no",           score: 30,  note: "Only if a binary answer is sufficient" },
  ],
  rating: [
    { type: "rating",           score: 100, note: "Best fit — icon-rated scale" },
    { type: "range",            score: 85,  note: "Animated scale — similar feel" },
    { type: "tap_card",         score: 50,  note: "Replace with sequential swipe cards" },
    { type: "multiple_choice",  score: 35,  note: "Flatten to a list of rating labels" },
  ],
  yes_no: [
    { type: "yes_no",           score: 100, note: "Best fit — simple binary gate" },
    { type: "multiple_choice",  score: 75,  note: "Expand to more defined options" },
    { type: "range",            score: 45,  note: "Use if nuance on a scale is needed" },
    { type: "tap_card",         score: 35,  note: "Sequential yes/no across statements" },
  ],
  open_ended: [
    { type: "open_ended",       score: 100, note: "Best fit — free-form qualitative voice" },
    { type: "multiple_choice",  score: 45,  note: "Constrain to predefined options" },
    { type: "range",            score: 30,  note: "Only if reducible to a single scale" },
  ],
  welcome_card: [
    { type: "welcome_card",     score: 100, note: "Best fit — cold audience intro card" },
    { type: "static_page",      score: 60,  note: "Use as a mid-survey break instead" },
  ],
  static_page: [
    { type: "static_page",      score: 100, note: "Best fit — off-screen activity break" },
    { type: "welcome_card",     score: 60,  note: "Use as an intro card instead" },
  ],
}

export default class extends Controller {
  static targets = [
    "card", "panelEmpty", "typeList", "panelFooter",
    "panelCardName", "panelHint", "typeOpt", "toast", "toastMsg", "cardCount"
  ]

  activeCardEl = null
  pendingType  = null

  selectCard(event) {
    if (event.target.closest("button[data-action*='deleteCard']")) return

    const card = event.currentTarget
    this.cardTargets.forEach(c => c.classList.remove("selected"))
    card.classList.add("selected")
    this.activeCardEl = card

    const cardType = card.dataset.cardType
    const cardNum  = card.dataset.cardNum
    this.pendingType = cardType

    const meta = TYPE_META[cardType]
    this.panelCardNameTarget.textContent = `Card ${cardNum} · ${meta?.badge || cardType}`
    this.panelHintTarget.textContent     = "Choose an answer format below."

    this.panelEmptyTarget.style.display  = "none"
    this.typeListTarget.style.display    = "flex"
    this.panelFooterTarget.style.display = "flex"

    this._renderCompatibleTypes(cardType)
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

  // ── private ──────────────────────────────────────────

  _renderCompatibleTypes(cardType) {
    const compat = COMPATIBILITY[cardType] || [{ type: cardType, score: 100, note: "" }]
    const compatMap = {}
    compat.forEach(c => { compatMap[c.type] = c })

    this.typeOptTargets.forEach(opt => {
      const type  = opt.dataset.type
      const entry = compatMap[type]

      if (!entry) {
        opt.style.display = "none"
        return
      }

      opt.style.display = ""
      opt.classList.toggle("active", type === cardType)

      // Remove any previously injected score badge
      opt.querySelector(".type-opt-score")?.remove()

      // Inject score badge
      const badge = document.createElement("div")
      badge.className = "type-opt-score"
      if (type === cardType) {
        badge.textContent = "Current"
        badge.setAttribute("data-primary", "true")
      } else {
        badge.textContent = `${entry.score}%`
      }

      // Insert before the radio dot
      const radio = opt.querySelector(".type-opt-radio")
      if (radio) radio.before(badge)

      // Update tooltip / description line with the note
      const descEl = opt.querySelector(".type-opt-desc")
      if (descEl && entry.note) descEl.textContent = entry.note
    })
  }

  _applyToCard(card, type) {
    const meta = TYPE_META[type]
    if (!meta) return

    const badge = card.querySelector(".s-badge")
    if (badge) { badge.textContent = meta.badge; badge.className = `s-badge ${meta.css}` }

    const eyebrow = card.querySelector(".q-eyebrow")
    if (eyebrow && meta.label) eyebrow.textContent = meta.label

    card.dataset.cardType = type

    if (card === this.activeCardEl) {
      const num = card.dataset.cardNum
      this.panelCardNameTarget.textContent = `Card ${num} · ${meta.badge}`
      this._renderCompatibleTypes(type)
      this.pendingType = type
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
