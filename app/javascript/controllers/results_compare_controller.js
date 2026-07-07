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
// White rather than the accent teal used for the density fill below — a
// teal stroke on a teal-tinted country (high response count) would be
// invisible against its own fill.
const MAP_SELECTED_STROKE = "#ffffff"

const SKIP_TYPES = new Set([ "welcome_card", "token_checkpoint" ])

export default class extends Controller {
  static targets = [ "panel", "meta", "picker", "body", "openBtn" ]
  static values  = { url: String }

  _data     = null
  _selected = new Set()
  _isOpen   = false
  _escHandler = null
  _mapData  = null
  _mapSvg   = null

  connect() {
    this._setupMap()
    this._loadPromise = this._loadData()
  }

  disconnect() {
    if (this._escHandler) document.removeEventListener("keydown", this._escHandler)
  }

  async _loadData() {
    try {
      const res = await fetch(this.urlValue, { headers: { "Accept": "application/json" } })
      this._data = await res.json()
    } catch (_) {
      this._data = null
      return
    }
    const overall = this._data.segments.find(s => s.id === "overall")
    const regions = this._data.segments.filter(s => s.id.startsWith("region_")).slice(0, 3)
    ;[ overall, ...regions ].filter(Boolean).forEach(s => this._selected.add(s.id))
    this._paintMap()
  }

  // ── Map: click a region to toggle it into the comparison ────────────────
  // The SVG only has country-level shapes, so a click toggles ALL of that
  // country's tagged region segments together — the smallest unit the map
  // can represent, even when a country holds several distinct regions.
  _setupMap() {
    this._mapSvg = this.element.querySelector(".world-map")
    const dataEl = document.getElementById("results-region-map-data")
    this._mapData = dataEl ? JSON.parse(dataEl.textContent) : {}
    if (!this._mapSvg) return

    Object.entries(this._mapData).forEach(([ cc, d ]) => {
      const el = this._mapSvg.querySelector("#" + cc)
      if (!el || !d.segment_ids.length) return
      el.classList.add("map-country")
      const tip = document.createElementNS("http://www.w3.org/2000/svg", "title")
      tip.textContent = `${d.name}: ${d.count}`
      el.appendChild(tip)
      el.addEventListener("click", () => this._toggleCountry(cc))
    })
    this._paintMap()
  }

  _toggleCountry(cc) {
    const ids = this._mapData[cc]?.segment_ids || []
    if (!ids.length) return
    const allSelected = ids.every(id => this._selected.has(id))
    ids.forEach(id => allSelected ? this._selected.delete(id) : this._selected.add(id))
    this._paintMap()
    if (this._isOpen && this._data) {
      this._renderPicker()
      this._renderBody()
    }
  }

  _paintMap() {
    if (!this._mapSvg || !this._mapData) return
    const max = Math.max(1, ...Object.values(this._mapData).map(d => d.count))
    Object.entries(this._mapData).forEach(([ cc, d ]) => {
      const el = this._mapSvg.querySelector("#" + cc)
      if (!el) return
      const paths = el.tagName.toLowerCase() === "g" ? el.querySelectorAll("path") : [ el ]
      const alpha = d.count === 0 ? 0.14 : 0.18 + 0.72 * (d.count / max)
      const selected = d.segment_ids.some(id => this._selected.has(id))
      paths.forEach(p => {
        p.style.fill = `rgba(1,234,203,${alpha.toFixed(2)})`
        p.style.stroke = selected ? MAP_SELECTED_STROKE : ""
        p.style.strokeWidth = selected ? "2.4" : ""
        p.style.filter = selected ? "drop-shadow(0 0 4px rgba(255,255,255,0.6))" : ""
      })
    })
  }

  // ── Panel open/close ─────────────────────────────────────────────────────
  async toggle() {
    if (this._isOpen) { this.close(); return }
    await this.open()
  }

  async open() {
    this._isOpen = true
    this.panelTarget.classList.remove("hidden")
    this.openBtnTarget.classList.add("is-active")

    if (!this._escHandler) {
      this._escHandler = (e) => { if (e.key === "Escape") this.close() }
    }
    document.addEventListener("keydown", this._escHandler)

    if (!this._data) {
      this.metaTarget.textContent = "Loading…"
      await this._loadPromise
    }
    if (!this._data) {
      this.metaTarget.textContent = "Couldn't load comparison data."
      return
    }

    this._renderPicker()
    this._renderBody()
  }

  close() {
    this._isOpen = false
    this.panelTarget.classList.add("hidden")
    this.openBtnTarget.classList.remove("is-active")
    if (this._escHandler) document.removeEventListener("keydown", this._escHandler)
  }

  toggleSegment(event) {
    const id = event.currentTarget.dataset.segmentId
    if (this._selected.has(id)) this._selected.delete(id); else this._selected.add(id)
    this._paintMap()
    this._renderPicker()
    this._renderBody()
  }

  _colorFor(id) {
    const idx = this._data.segments.findIndex(s => s.id === id)
    return idx >= 0 && idx < PALETTE.length ? PALETTE[idx] : FALLBACK_COLOR
  }

  _renderPicker() {
    this.metaTarget.textContent = `${this._selected.size} of ${this._data.segments.length} shown — click to add or remove`
    this.pickerTarget.innerHTML = ""
    this._data.segments.forEach(seg => {
      const chip = document.createElement("button")
      chip.type = "button"
      chip.className = `compare-chip${this._selected.has(seg.id) ? " is-active" : ""}`
      chip.dataset.segmentId = seg.id
      chip.dataset.action = "click->results-compare#toggleSegment"
      chip.innerHTML = `<span class="compare-chip-dot" style="background:${this._colorFor(seg.id)}"></span>` +
        `${esc(seg.label)} <span class="compare-chip-count">${seg.count}</span>`
      this.pickerTarget.appendChild(chip)
    })
  }

  _renderBody() {
    const selected = this._data.segments.filter(s => this._selected.has(s.id))
    this.bodyTarget.innerHTML = ""
    if (!selected.length) {
      this.bodyTarget.innerHTML = `<div class="compare-empty">Pick at least one segment above (or click a region on the map) to compare.</div>`
      return
    }
    this._data.cards.forEach(card => {
      const el = this._buildCardComparison(card, selected)
      if (el) this.bodyTarget.appendChild(el)
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
          const item = document.createElement("div")
          item.className = "compare-bar-item"
          item.innerHTML =
            `<div class="compare-bar-item-head">` +
              `<span class="compare-bar-item-label" style="color:${this._colorFor(seg.id)}" title="${esc(seg.label)}">` +
                `<span class="compare-chip-dot" style="background:${this._colorFor(seg.id)}"></span>${esc(seg.label)}` +
              `</span>` +
              `<span class="compare-bar-item-pct">${detail}</span>` +
            `</div>` +
            `<div class="compare-bar-track"><div class="compare-bar-fill" style="width:${pct}%;background:${this._colorFor(seg.id)}"></div></div>`
          group.appendChild(item)
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
