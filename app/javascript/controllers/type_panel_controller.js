import { Controller } from "@hotwired/stimulus"

// Maps panel type keys → badge text, badge CSS class, question eyebrow label
const TYPE_META = {
  range:    { badge: "RANGE",            css: "sb-range",    label: "DRAG THE SLIDER"   },
  pick:     { badge: "PICK ONE",         css: "sb-range",    label: "CHOOSE ONE"        },
  choice4:  { badge: "IMAGE CHOICE",     css: "sb-choice",   label: "CHOOSE ONE"        },
  choice6:  { badge: "IMAGE CHOICE × 6", css: "sb-choice",   label: "CHOOSE ONE"        },
  text:     { badge: "OPEN TEXT",        css: "sb-text",     label: "TYPE YOUR ANSWER"  },
  swipe:    { badge: "SWIPE",            css: "sb-swipe",    label: "SWIPE TO RESPOND"  },
  rotate:   { badge: "ROTATE",           css: "sb-range",    label: "TURN THE DIAL"     },
  rank:     { badge: "PRIORITISE",       css: "sb-rank",     label: "DRAG TO RANK"      },
  audio:    { badge: "AUDIO",            css: "sb-audio",    label: "RECORD A MESSAGE"  },
  video:    { badge: "VIDEO",            css: "sb-video",    label: "WATCH THE VIDEO"   },
  activity: { badge: "ACTIVITY",         css: "sb-activity", label: "COMPLETE THE TASK" },
  welcome:  { badge: "WELCOME CARD",     css: "sb-welcome",  label: ""                  },
}

// Maps internal survey card types → panel type keys
const INTERNAL_TO_PANEL = {
  welcome_card:     "welcome",
  range:            "range",
  rating:           "range",
  multiple_choice:  "pick",
  select_many:      "pick",
  yes_no:           "pick",
  select_one_grid:  "choice4",
  select_many_grid: "choice4",
  tap_card:         "swipe",
  open_ended:       "text",
  static_page:      "activity",
}

// Mini preview HTML builders
const PREVIEWS = {
  range: () =>
    `<div class="mini-tooltip">Neutral</div>
     <div class="mini-slider-track">
       <div class="mini-s-dot"></div><div class="mini-s-dot active"></div>
       <div class="mini-s-dot active"></div><div class="mini-s-dot"></div><div class="mini-s-dot"></div>
       <div class="mini-s-thumb"><div class="mini-s-line"></div><div class="mini-s-line"></div><div class="mini-s-line"></div></div>
     </div>`,

  pick: () =>
    `<div class="mini-pick-list">
       <div class="mini-pick-item selected"><span class="mini-p-dot selected"></span>Option A</div>
       <div class="mini-pick-item"><span class="mini-p-dot"></span>Option B</div>
       <div class="mini-pick-item"><span class="mini-p-dot"></span>Option C</div>
     </div>`,

  choice4: () =>
    `<div class="mini-img-grid">
       <div class="mini-img-card selected"><div class="mini-img-bg mini-bg-1"></div><div class="mini-img-ov"></div><div class="mini-img-lbl">A</div></div>
       <div class="mini-img-card"><div class="mini-img-bg mini-bg-2"></div><div class="mini-img-ov"></div><div class="mini-img-lbl">B</div></div>
       <div class="mini-img-card"><div class="mini-img-bg mini-bg-3"></div><div class="mini-img-ov"></div><div class="mini-img-lbl">C</div></div>
       <div class="mini-img-card"><div class="mini-img-bg mini-bg-4"></div><div class="mini-img-ov"></div><div class="mini-img-lbl">D</div></div>
     </div>`,

  choice6: () =>
    `<div class="mini-img-grid cols-3">
       <div class="mini-img-card selected" style="height:32px"><div class="mini-img-bg mini-bg-1"></div><div class="mini-img-ov"></div><div class="mini-img-lbl">A</div></div>
       <div class="mini-img-card" style="height:32px"><div class="mini-img-bg mini-bg-2"></div><div class="mini-img-ov"></div><div class="mini-img-lbl">B</div></div>
       <div class="mini-img-card" style="height:32px"><div class="mini-img-bg mini-bg-3"></div><div class="mini-img-ov"></div><div class="mini-img-lbl">C</div></div>
       <div class="mini-img-card" style="height:32px"><div class="mini-img-bg mini-bg-4"></div><div class="mini-img-ov"></div><div class="mini-img-lbl">D</div></div>
       <div class="mini-img-card" style="height:32px"><div class="mini-img-bg mini-bg-5"></div><div class="mini-img-ov"></div><div class="mini-img-lbl">E</div></div>
       <div class="mini-img-card" style="height:32px"><div class="mini-img-bg mini-bg-6"></div><div class="mini-img-ov"></div><div class="mini-img-lbl">F</div></div>
     </div>`,

  text: () => `<textarea class="mini-textarea" placeholder="Type your answer here…" readonly></textarea>`,

  swipe: () =>
    `<div class="mini-swipe-stack">
       <div class="mini-swipe-card c1"></div>
       <div class="mini-swipe-card c2"></div>
       <div class="mini-swipe-card c3"><span style="font-size:9px;color:rgba(0,0,0,0.5);padding:0 6px;text-align:center">Statement here</span></div>
     </div>
     <div class="mini-swipe-actions">
       <button class="mini-swipe-btn no">✕</button>
       <button class="mini-swipe-btn yes">✓</button>
     </div>`,

  rotate: () =>
    `<div style="display:flex;flex-direction:column;align-items:center;gap:6px">
       <div style="width:52px;height:52px;border-radius:50%;background:#4D588A;position:relative;display:flex;align-items:center;justify-content:center;box-shadow:0 4px 14px rgba(0,0,0,0.3)">
         <div style="position:absolute;top:4px;left:50%;transform:translateX(-50%);width:12px;height:12px;border-radius:50%;background:#00A950"></div>
         <span style="font-size:20px;transform:rotate(-20deg)">👍</span>
       </div>
       <div style="background:rgba(255,255,255,0.08);border-radius:6px;padding:3px 8px;font-size:9px;color:rgba(255,255,255,0.6)">Absolutely!</div>
     </div>`,

  rank: () =>
    `<div class="mini-priority-list">
       <div class="mini-priority-item"><div class="mini-rank">1</div>First option</div>
       <div class="mini-priority-item"><div class="mini-rank r2">2</div>Second option</div>
       <div class="mini-priority-item"><div class="mini-rank r3">3</div>Third option</div>
     </div>`,

  audio: () =>
    `<div style="display:flex;flex-direction:column;align-items:center;gap:6px">
       <div class="mini-mic">
         <svg viewBox="0 0 24 24" fill="white" width="18" height="18"><path d="M12 14c1.66 0 3-1.34 3-3V5c0-1.66-1.34-3-3-3S9 3.34 9 5v6c0 1.66 1.34 3 3 3zm5.3-3c0 3-2.54 5.1-5.3 5.1S6.7 14 6.7 11H5c0 3.41 2.72 6.23 6 6.72V21h2v-3.28c3.28-.48 6-3.3 6-6.72h-1.7z"/></svg>
       </div>
       <div style="font-size:9px;color:rgba(255,255,255,0.4);text-align:center">Tap mic to record</div>
     </div>`,

  video: () =>
    `<div style="width:100%;height:52px;background:#1C2034;border-radius:9px;position:relative;overflow:hidden;display:flex;align-items:center;justify-content:center">
       <div style="position:absolute;inset:0;background:rgba(0,0,0,0.3)"></div>
       <svg width="18" height="22" viewBox="0 0 45 55" fill="white" style="z-index:1"><path d="M0 4.455L0 50.545C0 54.059 3.859 56.195 6.831 54.282L42.937 31.237C45.688 29.502 45.688 25.498 42.937 23.718L6.831.718C3.859-1.195 0 .941 0 4.455z"/></svg>
     </div>`,

  activity: () =>
    `<div style="width:100%;display:flex;align-items:flex-start;gap:8px;padding:8px 10px;border-radius:10px;background:rgba(255,255,255,0.05)">
       <div style="width:16px;height:16px;border-radius:4px;background:#00A950;flex-shrink:0;display:flex;align-items:center;justify-content:center">
         <svg width="8" height="6" viewBox="0 0 12 9" fill="white"><path d="M3.712 7.295L1.21 4.79C.931 4.511.488 4.511.209 4.79-.07 5.069-.07 5.513.209 5.792L3.205 8.791c.278.279.729.279 1.008 0L11.791 1.211c.279-.279.279-.723 0-1.002-.279-.279-.722-.279-1.001 0z"/></svg>
       </div>
       <div style="font-size:9px;color:rgba(255,255,255,0.55);line-height:1.4">I've completed this activity</div>
     </div>`,

  welcome: () => `<div style="font-family:'Alata',sans-serif;font-size:11px;color:rgba(255,255,255,0.35);text-align:center">Welcome</div>`,
}

export default class extends Controller {
  static targets = [
    "card", "panelEmpty", "typeList", "panelFooter",
    "panelCardName", "panelHint", "typeOpt", "toast", "toastMsg", "cardCount"
  ]

  activeCardEl = null
  pendingType  = null

  selectCard(event) {
    const card = event.currentTarget
    this.cardTargets.forEach(c => c.classList.remove("selected"))
    card.classList.add("selected")
    this.activeCardEl = card

    const cardType  = card.dataset.cardType
    const cardNum   = card.dataset.cardNum
    const panelType = INTERNAL_TO_PANEL[cardType] || "pick"
    this.pendingType = panelType

    const badgeText = card.querySelector(".s-badge")?.textContent || cardType
    this.panelCardNameTarget.textContent = `Card ${cardNum} · ${badgeText}`
    this.panelHintTarget.textContent     = "Choose an answer format below."

    this.panelEmptyTarget.style.display  = "none"
    this.typeListTarget.style.display    = "flex"
    this.panelFooterTarget.style.display = "flex"

    this.typeOptTargets.forEach(o => o.classList.toggle("active", o.dataset.type === panelType))
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

    const badge = card.querySelector(".s-badge")
    if (badge) { badge.textContent = meta.badge; badge.className = `s-badge ${meta.css}` }

    const label = card.querySelector(".card-q-label")
    if (label) label.textContent = meta.label

    const preview  = card.querySelector(".left-preview")
    const buildFn  = PREVIEWS[type] || PREVIEWS.welcome
    if (preview) preview.innerHTML = buildFn()

    card.dataset.cardType = type

    if (card === this.activeCardEl) {
      const num = card.dataset.cardNum
      this.panelCardNameTarget.textContent = `Card ${num} · ${meta.badge}`
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
