import { Controller } from "@hotwired/stimulus"

// Categorical palette (dataviz skill's validated 8-hue dark-mode set,
// re-validated against this page's own dark surface #1C2034). Colour is
// assigned by SELECTION order, not by a segment's fixed position in the
// full segment list — a survey can have far more segments than the palette
// has hues, and colouring by list position meant most selected segments
// past the 8th ran permanently grey regardless of what was actually being
// compared. Only currently-selected segments get a hue at all; toggling a
// segment off frees its slot for the next thing selected, so a segment's
// colour CAN shift as others are toggled — an acceptable trade for never
// showing an active comparison in grey.
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
  static targets = [ "stage", "panel", "meta", "picker", "pickerWrap", "body", "openBtn", "mapStage" ]
  static values  = { url: String }

  _data     = null
  _selected = new Set()
  _isOpen   = false
  _escHandler = null
  _mapData  = null
  _mapSvg   = null
  _stagePlaceholder = null
  _countryForSegment = {}
  _worldViewBox = null
  _zoomRaf  = null

  // Compare mode moves the "stage" (map + panel) to <body> for full-screen
  // room, and its interactive bits (close button, picker chips, card
  // collapse toggles) are wired below with addEventListener rather than
  // data-action. Two things drive this:
  //  1. Stimulus target/action scope is DOM-proximity based to the
  //     controller root — once the stage is a child of <body> instead of
  //     this.element, anything inside it stops resolving as a target.
  //  2. Moving `this.element` ITSELF (rather than a child) doesn't work —
  //     confirmed by testing — because Stimulus treats the reparenting as
  //     a disconnect+reconnect of the whole controller (removedNodes on the
  //     old parent, addedNodes on the new one), which silently reverts any
  //     manual DOM move performed inside a lifecycle method and duplicates
  //     event listeners on reconnect. Caching plain element refs up front,
  //     once, sidesteps both problems entirely.
  connect() {
    this._stageEl      = this.stageTarget
    this._panelEl      = this.panelTarget
    this._metaEl       = this.metaTarget
    this._pickerEl     = this.pickerTarget
    this._pickerWrapEl = this.pickerWrapTarget
    this._bodyEl       = this.bodyTarget
    this._openBtnEl    = this.openBtnTarget
    this._mapStageEl   = this.mapStageTarget

    this._panelEl.querySelector(".compare-close-btn").addEventListener("click", () => this.close())

    this._setupMap()
    this._loadPromise = this._loadData()
  }

  disconnect() {
    if (this._escHandler) document.removeEventListener("keydown", this._escHandler)
    if (this._zoomRaf) cancelAnimationFrame(this._zoomRaf)
    this._exitFullscreen()
  }

  // Segments and their per-question aggregates are fetched here, no
  // separate request needed.
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

  // ── Map: click a country to toggle its region segment into the comparison ──
  // The SVG only has country-level shapes, and segments are now
  // country-granularity too (one region segment per country), so a click
  // toggles exactly the one segment tagged to that country.
  _setupMap() {
    this._mapSvg = this._stageEl.querySelector(".world-map")
    const dataEl = document.getElementById("results-region-map-data")
    this._mapData = dataEl ? JSON.parse(dataEl.textContent) : {}
    if (!this._mapSvg) return

    this._worldViewBox = this._mapSvg.getAttribute("viewBox").trim().split(/\s+/).map(Number)

    Object.entries(this._mapData).forEach(([ cc, d ]) => {
      const el = this._mapSvg.querySelector("#" + cc)
      if (!el || !d.segment_ids.length) return
      el.classList.add("map-country")
      const tip = document.createElementNS("http://www.w3.org/2000/svg", "title")
      tip.textContent = `${d.name}: ${d.count}`
      el.appendChild(tip)
      el.addEventListener("click", () => this._toggleCountry(cc))
      d.segment_ids.forEach(id => { this._countryForSegment[id] = cc })
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
      this._updateMapZoom()
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

  // ── Map zoom: when every compared segment shares one country, zoom in on
  // it for a closer look. Only active while the compare panel is open —
  // otherwise the small inline map preview would zoom in on its own, before
  // the user ever asked to compare anything. ─────────────────────────────
  _updateMapZoom() {
    if (!this._isOpen || !this._data) {
      this._zoomTo(this._worldViewBox)
      return
    }

    const regionIds = [ ...this._selected ].filter(id => id !== "overall")
    const countries = new Set(regionIds.map(id => this._countryForSegment[id]).filter(Boolean))

    if (countries.size === 1) {
      const cc = [ ...countries ][0]
      const countryEl = this._mapSvg.querySelector("#" + cc)
      if (countryEl) {
        const bbox = this._boundsElFor(countryEl).getBBox()
        const padX = Math.max(bbox.width * 0.4, 8)
        const padY = Math.max(bbox.height * 0.4, 8)
        this._zoomTo([ bbox.x - padX, bbox.y - padY, bbox.width + padX * 2, bbox.height + padY * 2 ])
        return
      }
    }

    this._zoomTo(this._worldViewBox)
  }

  // Multi-part countries (e.g. the US: mainland + Alaska + Hawaii + islands,
  // all under one <g>) mark their primary landmass with a "mainland" class.
  // Bounding the WHOLE group would span oceans of empty space between the
  // parts and place pins in the gap rather than on land — bound just the
  // mainland when there is one.
  _boundsElFor(countryEl) {
    return countryEl.querySelector(".mainland") || countryEl
  }

  _zoomTo(targetBox) {
    if (!this._mapSvg) return
    const from = this._mapSvg.viewBox.baseVal
    const start = [ from.x, from.y, from.width, from.height ]
    if (this._zoomRaf) cancelAnimationFrame(this._zoomRaf)

    const duration = 380
    const t0 = performance.now()
    const step = (now) => {
      const t = Math.min(1, (now - t0) / duration)
      const eased = t < 0.5 ? 2 * t * t : 1 - ((-2 * t + 2) ** 2) / 2
      const cur = start.map((v, i) => v + (targetBox[i] - v) * eased)
      this._mapSvg.setAttribute("viewBox", cur.join(" "))
      if (t < 1) this._zoomRaf = requestAnimationFrame(step)
    }
    this._zoomRaf = requestAnimationFrame(step)
  }

  // ── Panel open/close (full-screen) ──────────────────────────────────────
  async toggle() {
    if (this._isOpen) { this.close(); return }
    await this.open()
  }

  async open() {
    this._isOpen = true
    this._panelEl.classList.remove("hidden")
    this._pickerWrapEl.classList.remove("hidden")
    this._openBtnEl.classList.add("is-active")

    this._stagePlaceholder = document.createComment("compare-stage-placeholder")
    this._stageEl.before(this._stagePlaceholder)
    document.body.appendChild(this._stageEl)
    this._stageEl.classList.add("is-fullscreen")

    if (!this._escHandler) {
      this._escHandler = (e) => { if (e.key === "Escape") this.close() }
    }
    document.addEventListener("keydown", this._escHandler)

    if (!this._data) {
      this._metaEl.textContent = "Loading…"
      await this._loadPromise
    }
    if (!this._data) {
      this._metaEl.textContent = "Couldn't load comparison data."
      return
    }

    this._renderPicker()
    this._renderBody()
    this._updateMapZoom()
  }

  close() {
    this._isOpen = false
    this._panelEl.classList.add("hidden")
    this._pickerWrapEl.classList.add("hidden")
    this._openBtnEl.classList.remove("is-active")
    this._exitFullscreen()
    this._updateMapZoom()
    if (this._escHandler) document.removeEventListener("keydown", this._escHandler)
  }

  _exitFullscreen() {
    if (!this._stagePlaceholder) return
    this._stageEl.classList.remove("is-fullscreen")
    this._stagePlaceholder.replaceWith(this._stageEl)
    this._stagePlaceholder = null
  }

  _toggleSegment(id) {
    if (this._selected.has(id)) this._selected.delete(id); else this._selected.add(id)
    this._paintMap()
    this._renderPicker()
    this._renderBody()
    this._updateMapZoom()
  }

  _colorFor(id) {
    if (!this._selected.has(id)) return FALLBACK_COLOR
    const idx = [ ...this._selected ].indexOf(id)
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
      this._bodyEl.innerHTML = `<div class="compare-empty">Pick at least one segment above (or click a region on the map) to compare.</div>`
      return
    }
    this._data.cards.forEach(card => {
      const el = this._buildCardComparison(card, selected)
      if (el) this._bodyEl.appendChild(el)
    })
  }

  // Each card starts collapsed to just its question text behind a chevron
  // header — with the region picker no longer eating map space, the panel
  // is the one place still tight on room, so a long list of questions stays
  // scannable at a glance and expands one at a time on click.
  _buildCardComparison(card, selected) {
    if (SKIP_TYPES.has(card.type)) return null

    const wrap = document.createElement("div")
    wrap.className = "compare-card is-collapsed"

    const head = document.createElement("button")
    head.type = "button"
    head.className = "compare-card-head"
    head.innerHTML =
      `<span class="compare-card-chevron">▾</span>` +
      `<span class="compare-card-head-text">` +
        `<span class="compare-card-eyebrow">Card ${card.index + 1}</span>` +
        `<span class="compare-card-title">${esc(card.text || "")}</span>` +
      `</span>`
    head.addEventListener("click", () => wrap.classList.toggle("is-collapsed"))
    wrap.appendChild(head)

    const body = document.createElement("div")
    body.className = "compare-card-content"

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
