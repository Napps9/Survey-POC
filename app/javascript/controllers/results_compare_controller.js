import { Controller } from "@hotwired/stimulus"

// Categorical palette (dataviz skill's validated 8-hue dark-mode set,
// re-validated against this page's own dark surface #1C2034). Colour is
// assigned by each segment's fixed position in the full segment list — not
// by selection order — so a segment's colour never changes as others are
// toggled in/out.
const PALETTE = [
  "#3987e5", "#199e70", "#c98500", "#008300",
  "#9085e9", "#e66767", "#d55181", "#d95926"
]
const FALLBACK_COLOR = "rgba(255,255,255,0.4)"

const SKIP_TYPES = new Set([ "welcome_card", "token_checkpoint" ])

export default class extends Controller {
  static targets = [ "overlay", "meta", "picker", "body" ]
  static values  = { url: String }

  _data     = null
  _selected = new Set()
  _escHandler = null

  // The results page nests this controller inside an ancestor that has its
  // own z-index stacking context (for the AI insight sidebar layout), which
  // traps a nested position:fixed overlay below the app's top/bottom nav
  // bars no matter how high its own z-index goes. Move the overlay to be a
  // direct child of <body> so it stacks as a top-level modal instead —
  // capture plain element refs first since Stimulus's target/action scoping
  // stops working once an element leaves this controller's DOM scope, which
  // is also why the close button and picker chips below are wired with
  // plain addEventListener rather than data-action.
  connect() {
    this._overlayEl = this.overlayTarget
    this._metaEl    = this.metaTarget
    this._pickerEl  = this.pickerTarget
    this._bodyEl    = this.bodyTarget
    document.body.appendChild(this._overlayEl)

    this._overlayEl.querySelector(".compare-close-btn").addEventListener("click", () => this.close())
  }

  disconnect() {
    this._overlayEl?.remove()
    if (this._escHandler) document.removeEventListener("keydown", this._escHandler)
  }

  async open() {
    this._overlayEl.classList.remove("hidden")
    if (!this._escHandler) {
      this._escHandler = (e) => { if (e.key === "Escape") this.close() }
    }
    document.addEventListener("keydown", this._escHandler)

    if (!this._data) {
      this._metaEl.textContent = "Loading…"
      try {
        const res = await fetch(this.urlValue, { headers: { "Accept": "application/json" } })
        this._data = await res.json()
      } catch (_) {
        this._metaEl.textContent = "Couldn't load comparison data."
        return
      }
      const overall = this._data.segments.find(s => s.id === "overall")
      const regions = this._data.segments.filter(s => s.id.startsWith("region_")).slice(0, 3)
      ;[ overall, ...regions ].filter(Boolean).forEach(s => this._selected.add(s.id))
    }

    this._renderPicker()
    this._renderBody()
  }

  close() {
    this._overlayEl.classList.add("hidden")
    if (this._escHandler) document.removeEventListener("keydown", this._escHandler)
  }

  _toggleSegment(id) {
    if (this._selected.has(id)) this._selected.delete(id); else this._selected.add(id)
    this._renderPicker()
    this._renderBody()
  }

  _colorFor(id) {
    const idx = this._data.segments.findIndex(s => s.id === id)
    return idx >= 0 && idx < PALETTE.length ? PALETTE[idx] : FALLBACK_COLOR
  }

  _renderPicker() {
    this._metaEl.textContent = `${this._selected.size} of ${this._data.segments.length} shown — click to add or remove`
    this._pickerEl.innerHTML = ""
    this._data.segments.forEach(seg => {
      const chip = document.createElement("button")
      chip.type = "button"
      chip.className = `compare-chip${this._selected.has(seg.id) ? " is-active" : ""}`
      chip.dataset.segmentId = seg.id
      chip.innerHTML = `<span class="compare-chip-dot" style="background:${this._colorFor(seg.id)}"></span>` +
        `${esc(seg.label)} <span class="compare-chip-count">${seg.count}</span>`
      chip.addEventListener("click", () => this._toggleSegment(seg.id))
      this._pickerEl.appendChild(chip)
    })
  }

  _renderBody() {
    const selected = this._data.segments.filter(s => this._selected.has(s.id))
    this._bodyEl.innerHTML = ""
    if (!selected.length) {
      this._bodyEl.innerHTML = `<div class="compare-empty">Pick at least one segment above to compare.</div>`
      return
    }
    this._data.cards.forEach(card => {
      const el = this._buildCardComparison(card, selected)
      if (el) this._bodyEl.appendChild(el)
    })
  }

  _buildCardComparison(card, selected) {
    if (SKIP_TYPES.has(card.type)) return null

    const wrap = document.createElement("div")
    wrap.className = "compare-card"
    wrap.innerHTML = `<div class="compare-card-eyebrow">Card ${card.index + 1}</div>` +
      `<div class="compare-card-head">${esc(card.text || "")}</div>`

    const body = document.createElement("div")

    if (card.type === "open_ended") {
      selected.forEach(seg => {
        const agg = this._data.aggregates[seg.id][card.index]
        const row = document.createElement("div")
        row.className = "compare-freeform-note"
        row.innerHTML = `<span class="compare-chip-dot" style="background:${this._colorFor(seg.id)}"></span>` +
          `${esc(seg.label)} — ${(agg?.texts || []).length} free-text answer${(agg?.texts || []).length === 1 ? "" : "s"}`
        body.appendChild(row)
      })
    } else {
      this._rowKeysFor(card).forEach(({ key, label }) => {
        const group = document.createElement("div")
        group.className = "compare-option-group"
        const labelEl = document.createElement("div")
        labelEl.className = "compare-option-label"
        labelEl.textContent = label
        group.appendChild(labelEl)

        selected.forEach(seg => {
          const agg = this._data.aggregates[seg.id][card.index]
          const { pct, detail } = this._valueFor(card.type, agg, key)
          const row = document.createElement("div")
          row.className = "compare-bar-row"
          row.innerHTML =
            `<span class="compare-bar-seg" style="color:${this._colorFor(seg.id)}" title="${esc(seg.label)}">${esc(seg.label)}</span>` +
            `<div class="compare-bar-track"><div class="compare-bar-fill" style="width:${pct}%;background:${this._colorFor(seg.id)}"></div></div>` +
            `<span class="compare-bar-pct">${detail}</span>`
          group.appendChild(row)
        })
        body.appendChild(group)
      })
    }

    wrap.appendChild(body)
    return wrap
  }

  _rowKeysFor(card) {
    const overall = this._data.aggregates["overall"]?.[card.index]
    switch (card.type) {
      case "multiple_choice": case "yes_no": case "select_one_grid":
      case "select_many": case "select_many_grid": case "prioritise": case "tap_card": {
        const counts = overall?.counts || {}
        return Object.keys(counts)
          .sort((a, b) => this._sortWeight(card.type, counts, b) - this._sortWeight(card.type, counts, a))
          .map(k => ({ key: k, label: k }))
      }
      case "range": case "nps": {
        const labels = (card.options && card.options.length ? card.options : (card.type === "nps" ? Array.from({ length: 11 }, (_, i) => String(i)) : []))
        return labels.map((l, i) => ({ key: String(i), label: l }))
      }
      case "rating":
        return [ 5, 4, 3, 2, 1 ].map(n => ({ key: String(n), label: "★".repeat(n) }))
      default:
        return []
    }
  }

  _sortWeight(type, counts, key) {
    const v = counts[key]
    if (type === "tap_card") return (v?.yes || 0) + (v?.no || 0) + (v?.unsure || 0)
    return Number(v) || 0
  }

  _valueFor(type, agg, key) {
    if (!agg) return { pct: 0, detail: "0%" }
    const counts = agg.counts || {}

    if (type === "prioritise") {
      const values = Object.values(counts).map(Number)
      const n = Math.max(values.length, 1)
      const total = Math.max(agg.total || 1, 1)
      const mean = Number(counts[key] || 0) / total
      const pct = Math.max(0, Math.min(100, Math.round(((n - mean + 1) / n) * 100)))
      return { pct, detail: `avg ${mean.toFixed(1)}` }
    }

    if (type === "tap_card") {
      const dirs = counts[key] || {}
      const yes = Number(dirs.yes || 0), no = Number(dirs.no || 0), unsure = Number(dirs.unsure || 0)
      const tot = Math.max(yes + no + unsure, 1)
      const pct = Math.round((yes / tot) * 100)
      return { pct, detail: `${pct}% yes (${yes})` }
    }

    const grand = Math.max(Object.values(counts).reduce((s, v) => s + Number(v || 0), 0), 1)
    const count = Number(counts[key] || 0)
    const pct = Math.round((count / grand) * 100)
    return { pct, detail: `${pct}% (${count})` }
  }
}

function esc(s) {
  return String(s ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;")
                       .replace(/>/g, "&gt;").replace(/"/g, "&quot;")
}
