import { Controller } from "@hotwired/stimulus"

const TYPE_META = {
  range:            { badge: "RANGE",         css: "sb-range",    label: "DRAG THE SLIDER",       eyebrow: "Drag the slider"        },
  rating:           { badge: "RATING",         css: "sb-range",    label: "DRAG THE SLIDER",       eyebrow: "Drag the slider"        },
  multiple_choice:  { badge: "PICK ONE",       css: "sb-range",    label: "CHOOSE ONE",            eyebrow: "Choose one"             },
  select_many:      { badge: "SELECT MANY",    css: "sb-range",    label: "CHOOSE ALL THAT APPLY", eyebrow: "Choose all that apply"  },
  yes_no:           { badge: "YES / NO",       css: "sb-range",    label: "CHOOSE ONE",            eyebrow: "Choose one"             },
  select_one_grid:  { badge: "IMAGE GRID",     css: "sb-choice",   label: "CHOOSE ONE",            eyebrow: "Choose one"             },
  select_many_grid: { badge: "IMAGE GRID",     css: "sb-choice",   label: "CHOOSE ALL THAT APPLY", eyebrow: "Choose all that apply"  },
  tap_card:         { badge: "SWIPE",          css: "sb-swipe",    label: "SWIPE TO RESPOND",      eyebrow: "Swipe to respond"       },
  open_ended:       { badge: "OPEN TEXT",      css: "sb-text",     label: "TYPE YOUR ANSWER",      eyebrow: "Type your answer"       },
  static_page:      { badge: "ACTIVITY",       css: "sb-activity", label: "COMPLETE THE TASK",     eyebrow: ""                       },
  welcome_card:     { badge: "WELCOME CARD",   css: "sb-welcome",  label: "",                      eyebrow: ""                       },
}

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

const DEFAULT_OPTIONS = {
  range:            ["Strongly disagree", "Disagree", "Neutral", "Agree", "Strongly agree"],
  rating:           ["Poor", "Fair", "Good", "Great", "Excellent"],
  multiple_choice:  ["Option A", "Option B", "Option C"],
  select_many:      ["Option A", "Option B", "Option C", "Option D"],
  yes_no:           ["Yes", "No"],
  select_one_grid:  ["A", "B", "C", "D"],
  select_many_grid: ["A", "B", "C", "D"],
  tap_card:         ["Statement 1", "Statement 2", "Statement 3"],
  open_ended:       [],
  static_page:      [],
  welcome_card:     [],
}

const SWIPE_FILLS = [
  ["#d4edda","#a8d5b5"], ["#d1ecf1","#9fd5df"], ["#fff3cd","#ffd88a"],
  ["#f8d7da","#f5a8b0"], ["#e2d9f3","#c3aee8"]
]

function esc(s) {
  return String(s ?? "").replace(/&/g,"&amp;").replace(/</g,"&lt;")
                       .replace(/>/g,"&gt;").replace(/"/g,"&quot;")
}

// HTML builders for the right-side interactive component on each card
const COMPONENTS = {
  multiple_choice: (opts) => `
    <ul class="pick-list" data-controller="picker" data-picker-mode-value="single">
      ${opts.map(o => `
        <li class="pick-item" data-picker-target="item" data-action="click->picker#pick" data-selected="false">
          <span class="pick-dot">✓</span>
          <span class="pick-text">${esc(o)}</span>
        </li>`).join("")}
    </ul>`,

  select_many: (opts) => `
    <ul class="pick-list" data-controller="picker" data-picker-mode-value="multi">
      ${opts.map(o => `
        <li class="pick-item" data-picker-target="item" data-action="click->picker#pick" data-selected="false">
          <span class="pick-square">✓</span>
          <span class="pick-text">${esc(o)}</span>
        </li>`).join("")}
    </ul>`,

  yes_no: () => `
    <ul class="pick-list" data-controller="picker" data-picker-mode-value="single">
      ${["Yes","No"].map(o => `
        <li class="pick-item" data-picker-target="item" data-action="click->picker#pick" data-selected="false">
          <span class="pick-dot">✓</span>
          <span class="pick-text">${o}</span>
        </li>`).join("")}
    </ul>`,

  select_one_grid:  (opts) => gridHtml(opts, "single"),
  select_many_grid: (opts) => gridHtml(opts, "multi"),

  tap_card: (opts) => `
    <div class="rotate-wrap" data-controller="tap-stack">
      <div class="rotate-card-stack">
        ${opts.map((o,i) => {
          const [a,b] = SWIPE_FILLS[i % SWIPE_FILLS.length]
          return `<div class="rotate-card" data-tap-stack-target="card"
                       style="background:linear-gradient(135deg,${a},${b});">
                    <span>${esc(o)}</span>
                  </div>`
        }).join("")}
      </div>
      <div class="swipe-indicator">
        <span style="color:#D80027;font-weight:700">← No</span>
        <span class="mx-3">drag card to answer</span>
        <span style="color:#00A950;font-weight:700">Yes →</span>
      </div>
      <div class="rotate-actions">
        <button type="button" class="rotate-action-btn rotate-action-no"
                data-action="click->tap-stack#pick" data-tap-stack-direction="left">✕</button>
        <button type="button" class="rotate-action-btn rotate-action-yes"
                data-action="click->tap-stack#pick" data-tap-stack-direction="right">✓</button>
      </div>
    </div>`,

  range:  (opts) => sliderHtml(opts),
  rating: (opts) => sliderHtml(opts),

  open_ended: () => `
    <div class="freeform-wrap" data-controller="freeform" data-freeform-max-value="200">
      <textarea class="freeform-textarea" placeholder="Type answer…"
                data-freeform-target="input"
                data-action="input->freeform#update"></textarea>
      <div class="freeform-counter" data-freeform-target="counter">0/200 Characters</div>
    </div>`,

  welcome_card: () => "",
  static_page:  () => "",
}

function gridHtml(opts, mode) {
  const cols = opts.length >= 5 ? 3 : 2
  const indicator = mode === "multi" ? "pick-square" : "pick-dot"
  return `
    <ul class="choice-grid choice-grid-${cols}" data-controller="picker"
        data-picker-mode-value="${mode}">
      ${opts.map((o,i) => `
        <li class="choice-card" data-picker-target="item"
            data-action="click->picker#pick" data-selected="false">
          <div class="choice-card-bg choice-bg-${(i % 6) + 1}"></div>
          <div class="choice-overlay"></div>
          <div class="choice-tick">✓</div>
          <div class="choice-label">${esc(o)}</div>
        </li>`).join("")}
    </ul>`
}

function sliderHtml(opts) {
  const labels = opts.length ? opts : DEFAULT_OPTIONS.range
  const n = Math.max(labels.length, 2)
  const dots = Array.from({length: n}, (_, i) =>
    `<div class="s-dot" data-slider-target="dot" style="left:${(i / (n - 1) * 100).toFixed(2)}%"></div>`
  ).join("")
  return `
    <div class="slider-wrap" data-controller="slider" data-slider-steps-value="${n}">
      <div class="slider-track-wrap">
        <div class="slider-tooltip" data-slider-target="tooltip" style="left:50%;">
          <span class="slider-tooltip-text" data-slider-target="tooltipText"></span>
        </div>
        <div class="slider-track" data-slider-target="track"
             data-action="pointerdown->slider#start">
          ${dots}
          <div class="slider-thumb" data-slider-target="thumb" style="left:50%;">
            <div class="s-line"></div><div class="s-line"></div><div class="s-line"></div>
          </div>
        </div>
      </div>
      <div class="slider-labels">
        ${labels.map(o => `<span class="slider-label-text">${esc(o)}</span>`).join("")}
      </div>
    </div>`
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
    const compatMap = Object.fromEntries(compat.map(c => [c.type, c]))

    this.typeOptTargets.forEach(opt => {
      const type  = opt.dataset.type
      const entry = compatMap[type]

      if (!entry) { opt.style.display = "none"; return }

      opt.style.display = ""
      opt.classList.toggle("active", type === cardType)

      opt.querySelector(".type-opt-score")?.remove()
      const badge = document.createElement("div")
      badge.className = "type-opt-score"
      if (type === cardType) {
        badge.textContent = "Current"
        badge.setAttribute("data-primary", "true")
      } else {
        badge.textContent = `${entry.score}%`
      }
      const radio = opt.querySelector(".type-opt-radio")
      if (radio) radio.before(badge)

      const descEl = opt.querySelector(".type-opt-desc")
      if (descEl && entry.note) descEl.textContent = entry.note
    })
  }

  _applyToCard(card, type) {
    const meta = TYPE_META[type]
    if (!meta) return

    // 1. Update badge + eyebrow
    const badge = card.querySelector(".s-badge")
    if (badge) { badge.textContent = meta.badge; badge.className = `s-badge ${meta.css}` }

    const eyebrow = card.querySelector(".q-eyebrow")
    if (eyebrow) eyebrow.textContent = meta.eyebrow

    // 2. Swap the interactive component HTML
    const slot = card.querySelector("[data-card-component]")
    if (slot) {
      const opts = this._optionsFor(card, type)
      const builder = COMPONENTS[type] || (() => "")
      slot.innerHTML = builder(opts)
    }

    card.dataset.cardType = type

    if (card === this.activeCardEl) {
      const num = card.dataset.cardNum
      this.panelCardNameTarget.textContent = `Card ${num} · ${meta.badge}`
      this._renderCompatibleTypes(type)
      this.pendingType = type
    }
  }

  _optionsFor(card, type) {
    let original = []
    try { original = JSON.parse(card.dataset.cardOptions || "[]") } catch (_) {}
    if (type === "yes_no") return ["Yes", "No"]
    if (original.length) return original
    return DEFAULT_OPTIONS[type] || []
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
