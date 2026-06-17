import { Controller } from "@hotwired/stimulus"
import { t } from "lib/i18n"

export default class extends Controller {
  static targets = ["card", "backBtn", "nextBtn", "finishBtn", "thankyou", "progress",
                    "thankyouMain", "compareBtn", "comparison", "comparisonList", "comparisonMeta",
                    "regionsBtn", "regionsPanel", "regionsMain", "regionsMeta", "regionsList",
                    "regionDetail", "regionDetailTitle", "regionDetailList", "shareBtn", "requiredHint"]
  static values  = {
    progressUrl: { type: String, default: "" },
    submitUrl: String,
    resultsUrl: { type: String, default: "" },
    regionsUrl: { type: String, default: "" },
    regionCountry: { type: String, default: "" },
    regionLabel: { type: String, default: "" },
    locale: { type: String, default: "" },
    shareUrl: { type: String, default: "" },
    showComparison: { type: Boolean, default: false },
    current: { type: Number, default: 0 }
  }

  _answers = {}
  _registered = false
  _regionOptOut = false
  _regionsData = null

  connect() {
    this._sessionToken = this._ensureToken()
    this._update()
  }

  next() {
    this._capture(this.currentValue)
    if (!this._requireGuard(this.currentValue)) return
    this._saveProgress()
    if (this.currentValue < this.cardTargets.length - 1) {
      this.currentValue++
      this._update()
    }
  }

  back() {
    this._capture(this.currentValue)
    this._saveProgress()
    if (this.currentValue > 0) {
      this.currentValue--
      this._update()
    }
  }

  // Region choice travels with every save. The opt-out flag is explicit so
  // the server clears a link-borne region too — consent always wins.
  _payload() {
    const payload = { session_token: this._sessionToken, answers: this._answers, locale: this.localeValue }
    payload.region_opt_out = this._regionOptOut
    if (!this._regionOptOut && this.regionCountryValue) {
      payload.region_country = this.regionCountryValue
      payload.region_label   = this.regionLabelValue
    }
    return payload
  }

  // Base-link respondents pick their region from the Verto's tags ("" = prefer
  // not to say). Option values are "CC|label".
  setRegion(e) {
    const v   = e.target.value || ""
    const sep = v.indexOf("|")
    this.regionCountryValue = sep >= 0 ? v.slice(0, sep) : v
    this.regionLabelValue   = sep >= 0 ? v.slice(sep + 1) : ""
    this._regionOptOut = v === ""
    this._resaveRegion()
  }

  // Ask-players mode: country and free-text area arrive separately.
  setRegionCountry(e) {
    this.regionCountryValue = e.target.value || ""
    this._regionOptOut = false
    this._resaveRegion()
  }

  setRegionArea(e) {
    this.regionLabelValue = e.target.value.trim()
    this._resaveRegion()
  }

  // Link-borne region: the notice bar's opt-out toggle.
  toggleRegionOptOut(e) {
    this._regionOptOut = !this._regionOptOut
    e.target.textContent = t(this._regionOptOut ? "player.region_optin" : "player.region_optout")
    this._resaveRegion()
  }

  // If progress already registered this session, push the new region consent
  // state immediately rather than waiting for the next navigation.
  _resaveRegion() {
    if (!this._registered) return
    this._registered = false
    this._saveProgress()
  }

  async finish() {
    this._capture(this.currentValue)
    if (!this._requireGuard(this.currentValue)) return
    // Owner preview runs without a submit endpoint — nothing is recorded,
    // just show the thank-you screen.
    if (!this.submitUrlValue) return this._showThankyou(false)
    let queued = false
    try {
      const res = await fetch(this.submitUrlValue, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(this._payload())
      })
      if (!res.ok) throw new Error(`HTTP ${res.status}`)
      const data = await res.clone().json().catch(() => null)
      queued = !!(data && data.queued)
    } catch (_) {
      // No SW running and offline — answers are lost. Still show thank-you
      // so the player completes; flag as queued to set expectations.
      queued = !navigator.onLine
    }
    this._showThankyou(queued)
  }

  // Share the public play link so respondents can pass the Verto on. Uses the
  // native share sheet where available (mobile), falling back to copying the
  // link to the clipboard with a brief ✓ on the button (desktop).
  async share() {
    const url = this.shareUrlValue || window.location.href
    if (navigator.share) {
      try {
        await navigator.share({ title: document.title, url })
      } catch (_) {
        // Sheet dismissed or failed — nothing more to do.
      }
      return
    }
    try {
      await navigator.clipboard.writeText(url)
      if (this.hasShareBtnTarget) {
        const btn = this.shareBtnTarget
        const original = btn.textContent
        btn.textContent = "✓"
        setTimeout(() => { btn.textContent = original }, 1800)
      }
    } catch (_) {
      window.prompt("", url)
    }
  }

  // A stable per-session token: persisted so a refresh reuses the same
  // response row rather than creating a duplicate.
  _ensureToken() {
    const newToken = () =>
      (typeof crypto !== "undefined" && crypto.randomUUID)
        ? crypto.randomUUID()
        : Math.random().toString(36).slice(2)
    const key = `verto_session_${this.submitUrlValue}`
    try {
      let t = sessionStorage.getItem(key)
      if (!t) { t = newToken(); sessionStorage.setItem(key, t) }
      return t
    } catch (_) {
      return newToken()
    }
  }

  // Register this session as a responder once it has ≥1 real answer, so people
  // who answer something then leave are still counted. Fire once on success.
  async _saveProgress() {
    if (this._registered || !this.progressUrlValue) return
    const hasAnswer = Object.values(this._answers).some(a => a && this._isAnswered(a.value))
    if (!hasAnswer) return
    try {
      const res = await fetch(this.progressUrlValue, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(this._payload())
      })
      if (res.ok) this._registered = true
    } catch (_) { /* retry on the next navigation */ }
  }

  _isAnswered(value) {
    if (Array.isArray(value)) return value.length > 0
    return value !== null && value !== undefined && value !== ""
  }

  // Whether the card at `idx` has a usable answer (a value, or free-text Other).
  _isCardAnswered(idx) {
    const a = this._answers[String(idx)]
    if (!a) return false
    if (a.other && a.other.trim()) return true
    return this._isAnswered(a.value)
  }

  // Required gate: a card marked data-card-required must be answered before the
  // player advances past it. Returns true when it's safe to proceed.
  _requireGuard(idx) {
    const card = this.cardTargets[idx]
    if (!card || card.dataset.cardRequired !== "true" || this._isCardAnswered(idx)) {
      this._clearRequiredHint()
      return true
    }
    this._showRequiredHint(card)
    return false
  }

  _showRequiredHint(card) {
    if (this.hasRequiredHintTarget) this.requiredHintTarget.classList.remove("hidden")
    if (card) {
      card.classList.remove("card-shake")
      void card.offsetWidth // reflow so the shake restarts on a repeated tap
      card.classList.add("card-shake")
    }
  }

  _clearRequiredHint() {
    if (this.hasRequiredHintTarget) this.requiredHintTarget.classList.add("hidden")
  }

  _capture(idx) {
    const card = this.cardTargets[idx]
    if (!card) return
    const type  = card.dataset.cardType
    const value = this._read(card, type)
    // "Other" is a standalone answer: if the respondent typed free text it
    // replaces any normal selection for this card.
    const other = card.querySelector("[data-other-input]")?.value.trim()
    this._answers[String(idx)] = other
      ? { type, value: null, other }
      : { type, value }
  }

  // The canonical (primary-language) label an option element answers as.
  _canonicalOf(el) {
    if (!el) return null
    const c = el.dataset.canonical
    if (c !== undefined && c !== "") return c
    return el.querySelector(".pick-text, .choice-label")?.textContent.trim() ?? null
  }

  _read(card, type) {
    switch (type) {
      // Choice answers store the CANONICAL (primary-language) option label, so
      // results aggregate across languages regardless of the displayed text.
      case "multiple_choice":
      case "yes_no":
      case "select_one_grid":
        return this._canonicalOf(
          card.querySelector('[data-picker-target="item"][data-selected="true"]')
        )

      case "select_many":
      case "select_many_grid":
        return Array.from(card.querySelectorAll('[data-picker-target="item"][data-selected="true"]'))
                    .map(el => this._canonicalOf(el))
                    .filter(v => v !== null)

      case "range": {
        const dots   = Array.from(card.querySelectorAll(".s-dot"))
        const active = dots.findIndex(d => d.classList.contains("active"))
        return active >= 0 ? active : null
      }

      case "nps": {
        const el = card.querySelector(".nps-slider")
        if (el) {
          const v = el.dataset.npsValue
          return (v !== undefined && v !== "") ? Number(v) : null
        }
        // Feature flag off: the card is rendered as a plain range slider.
        const dots   = Array.from(card.querySelectorAll(".s-dot"))
        const active = dots.findIndex(d => d.classList.contains("active"))
        return active >= 0 ? active : null
      }

      case "rating": {
        const count = Array.from(card.querySelectorAll(".rating-star.active")).length
        return count > 0 ? count : null
      }

      case "tap_card": {
        const wrap = card.querySelector(".rotate-wrap")
        try { return JSON.parse(wrap?.dataset.swipeResults || "null") } catch { return null }
      }

      case "open_ended": {
        const el = card.querySelector("textarea, input[type='date']")
        return el?.value?.trim() || null
      }

      default:
        return null
    }
  }

  _showThankyou(queued = false) {
    this.cardTargets.forEach(c => c.classList.remove("active"))
    this.thankyouTarget.classList.add("active")
    this.backBtnTarget.classList.add("hidden")
    this.nextBtnTarget.classList.add("hidden")
    this.finishBtnTarget.classList.add("hidden")
    this.progressTarget.textContent = ""
    if (queued && this.hasThankyouMainTarget && !this.thankyouMainTarget.querySelector(".preview-queued-pill")) {
      const pill = document.createElement("div")
      pill.className = "preview-queued-pill"
      pill.textContent = t("player.queued")
      this.thankyouMainTarget.appendChild(pill)
    }
  }

  async showComparison() {
    if (!this.showComparisonValue || !this.resultsUrlValue) return
    if (this.hasCompareBtnTarget) {
      this.compareBtnTarget.disabled = true
      this.compareBtnTarget.textContent = t("player.compare_loading")
    }
    try {
      const res  = await fetch(this.resultsUrlValue, { headers: { "Accept": "application/json" } })
      const data = await res.json()
      if (!data.ok) throw new Error(data.error || "Failed to load results")
      this._renderComparison(data)
      this.thankyouMainTarget.classList.add("hidden")
      this.comparisonTarget.classList.remove("hidden")
    } catch (e) {
      if (this.hasCompareBtnTarget) {
        this.compareBtnTarget.disabled = false
        this.compareBtnTarget.textContent = t("player.compare_error")
      }
    }
  }

  hideComparison() {
    if (this.hasComparisonTarget) this.comparisonTarget.classList.add("hidden")
    if (this.hasThankyouMainTarget) this.thankyouMainTarget.classList.remove("hidden")
    if (this.hasCompareBtnTarget) {
      this.compareBtnTarget.disabled = false
      this.compareBtnTarget.textContent = t("player.compare_cta")
    }
  }

  // ── Regions map: where answers came from, per-region comparison ──

  async showRegions() {
    if (!this.regionsUrlValue || !this.hasRegionsPanelTarget) return
    this.thankyouMainTarget.classList.add("hidden")
    if (this.hasComparisonTarget) this.comparisonTarget.classList.add("hidden")
    this.regionsPanelTarget.classList.remove("hidden")
    if (this._regionsData) return
    this.regionsMetaTarget.textContent = t("player.compare_loading")
    try {
      const res  = await fetch(this.regionsUrlValue, { headers: { "Accept": "application/json" } })
      const data = await res.json()
      if (!data.ok) throw new Error(data.error || "Failed to load regions")
      this._regionsData = data
      this._renderRegions(data)
    } catch (_) {
      this.regionsMetaTarget.textContent = t("player.compare_error")
    }
  }

  // Back button: detail view returns to the map, the map closes the panel.
  hideRegions() {
    if (this.hasRegionDetailTarget && !this.regionDetailTarget.classList.contains("hidden")) {
      this.regionDetailTarget.classList.add("hidden")
      this.regionsMainTarget.classList.remove("hidden")
      return
    }
    this.regionsPanelTarget.classList.add("hidden")
    this.thankyouMainTarget.classList.remove("hidden")
  }

  _renderRegions(data) {
    const regions = data.regions || []
    this.regionsMetaTarget.textContent = t("player.region_meta", { count: data.total_tagged || 0 })

    // Choropleth: tint each country by its share of region-tagged responses.
    // Some countries are <g> groups — inline fill must land on the paths to
    // beat the stylesheet's base fill.
    const byCountry = {}
    regions.forEach(r => { byCountry[r.country] = (byCountry[r.country] || 0) + r.responders })
    const max = Math.max(1, ...Object.values(byCountry))
    const svg = this.regionsPanelTarget.querySelector(".world-map")
    if (svg) Object.entries(byCountry).forEach(([cc, n]) => {
      const el = svg.querySelector(`#${cc.toLowerCase()}`)
      if (!el) return
      const alpha = 0.18 + 0.72 * (n / max)
      const paths = el.tagName.toLowerCase() === "g" ? el.querySelectorAll("path") : [el]
      paths.forEach(p => { p.style.fill = `rgba(1,234,203,${alpha.toFixed(2)})` })
      const tip = document.createElementNS("http://www.w3.org/2000/svg", "title")
      tip.textContent = `${regions.find(r => r.country === cc)?.country_name || cc}: ${n}`
      el.appendChild(tip)
      el.style.cursor = "pointer"
      el.addEventListener("click", () => this._highlightCountry(cc))
    })

    const list = this.regionsListTarget
    list.innerHTML = ""
    if (regions.length === 0) {
      const empty = document.createElement("div")
      empty.style.cssText = "font-family:'ABeeZee',sans-serif;font-size:12px;color:rgba(255,255,255,0.5);text-align:center;padding:10px;"
      empty.textContent = t("player.region_empty")
      list.appendChild(empty)
      return
    }
    regions.forEach(region => {
      const row = document.createElement("button")
      row.type = "button"
      row.className = "region-row"
      row.dataset.country = region.country
      const name = document.createElement("span")
      name.style.cssText = "flex:1;text-align:start;font-family:'ABeeZee',sans-serif;font-size:13px;color:#fff;"
      name.textContent = region.label ? `${region.country_name} · ${region.label}` : region.country_name
      const count = document.createElement("span")
      count.style.cssText = "font-family:'Alata',sans-serif;font-size:12px;color:#01EACB;"
      count.textContent = t("player.region_answered", { count: region.responders })
      const arrow = document.createElement("span")
      arrow.style.cssText = "font-family:'ABeeZee',sans-serif;font-size:12px;color:rgba(255,255,255,0.45);"
      arrow.textContent = t("player.region_compare")
      row.append(name, count, arrow)
      row.addEventListener("click", () => this._showRegionDetail(region))
      list.appendChild(row)
    })
  }

  _highlightCountry(cc) {
    this.regionsListTarget.querySelectorAll(".region-row").forEach(row => {
      row.classList.toggle("active-country", row.dataset.country === cc)
    })
    const first = this.regionsListTarget.querySelector(`.region-row[data-country="${cc}"]`)
    if (first) first.scrollIntoView({ behavior: "smooth", block: "nearest" })
  }

  // Region vs you: reuses the comparison row renderer, so each question shows
  // the region's distribution with this respondent's own answer highlighted.
  _showRegionDetail(region) {
    this.regionsMainTarget.classList.add("hidden")
    this.regionDetailTarget.classList.remove("hidden")
    const name = region.label ? `${region.country_name} · ${region.label}` : region.country_name
    this.regionDetailTitleTarget.textContent =
      `${name} — ${t("player.region_answered", { count: region.responders })}`
    const list = this.regionDetailListTarget
    list.innerHTML = ""
    ;(region.results || []).forEach(row => {
      if (row.type === "welcome_card") return
      const mine = this._answers[String(row.index)]?.value
      list.appendChild(this._buildRow(row, mine))
    })
  }

  _renderComparison(data) {
    const total = data.total_responses || 0
    if (this.hasComparisonMetaTarget) {
      this.comparisonMetaTarget.textContent =
        `Based on ${total} response${total === 1 ? "" : "s"} (including yours)`
    }
    const list = this.comparisonListTarget
    list.innerHTML = ""
    ;(data.results || []).forEach(row => {
      if (row.type === "welcome_card") return
      const mine = this._answers[String(row.index)]?.value
      list.appendChild(this._buildRow(row, mine))
    })
  }

  _buildRow(row, mine) {
    const wrap = document.createElement("div")
    wrap.style.cssText = "background:rgba(255,255,255,0.04);border:1px solid rgba(255,255,255,0.08);border-radius:14px;padding:14px 16px;"

    const prompt = document.createElement("div")
    prompt.style.cssText = "font-family:'ABeeZee',sans-serif;font-size:13px;color:#fff;line-height:1.45;margin-bottom:10px;"
    prompt.textContent = row.prompt || `Question ${row.index + 1}`
    wrap.appendChild(prompt)

    const yourPill = document.createElement("div")
    yourPill.style.cssText = "display:inline-block;padding:4px 10px;border-radius:100px;background:var(--brand-primary-soft,rgba(1,234,203,0.15));color:var(--brand-primary,#01EACB);font-family:'ABeeZee',sans-serif;font-size:11px;margin-bottom:10px;"
    yourPill.textContent = `Your answer: ${this._formatMine(mine, row)}`
    wrap.appendChild(yourPill)

    const body = this._buildDistribution(row, mine)
    if (body) wrap.appendChild(body)

    return wrap
  }

  _formatMine(mine, row) {
    if (mine === null || mine === undefined || mine === "") return "—"
    if (Array.isArray(mine)) return mine.length ? mine.join(", ") : "—"
    if ((row.type === "range" || row.type === "nps") && Array.isArray(row.options)) {
      return row.options[mine] || `Step ${Number(mine) + 1}`
    }
    if (row.type === "rating") return `${mine} ★`
    if (typeof mine === "object") {
      return Object.entries(mine).map(([k, v]) => `${k}: ${v}`).join(", ")
    }
    return String(mine)
  }

  _buildDistribution(row, mine) {
    const container = document.createElement("div")
    container.style.cssText = "display:flex;flex-direction:column;gap:6px;"

    const counts = row.counts || {}
    let entries = []

    if ((row.type === "range" || row.type === "nps") && Array.isArray(row.options)) {
      entries = row.options.map((label, i) => [label, counts[i] || counts[String(i)] || 0, i])
    } else if (row.type === "rating") {
      const max = Math.max(5, ...Object.keys(counts).map(k => parseInt(k) || 0))
      for (let i = 1; i <= max; i++) entries.push([`${i} ★`, counts[i] || counts[String(i)] || 0, i])
    } else if (row.type === "open_ended") {
      const note = document.createElement("div")
      note.style.cssText = "font-family:'ABeeZee',sans-serif;font-size:11px;color:rgba(255,255,255,0.4);font-style:italic;"
      note.textContent = `${row.total || 0} open-ended response${row.total === 1 ? "" : "s"} total`
      container.appendChild(note)
      return container
    } else if (row.type === "tap_card") {
      Object.entries(counts).forEach(([label, yn]) => {
        const yes = (yn && yn.yes) || 0, no = (yn && yn.no) || 0, sum = yes + no || 1
        entries.push([`${label} — Yes`, yes, `${label}:yes`, sum])
        entries.push([`${label} — No`,  no,  `${label}:no`,  sum])
      })
    } else {
      entries = Object.entries(counts).map(([label, n]) => [label, n, label])
    }

    if (entries.length === 0) return null

    const grand = entries.reduce((s, e) => s + (e[3] || e[1]), 0) || 1
    entries.forEach(([label, count, key, denom]) => {
      const pct = Math.round((count / (denom || grand)) * 100)
      const isMine = this._isMineMatch(mine, key, row)
      container.appendChild(this._buildBar(label, count, pct, isMine))
    })
    return container
  }

  _isMineMatch(mine, key, row) {
    if (mine === null || mine === undefined) return false
    if (Array.isArray(mine)) return mine.map(String).includes(String(key))
    if (row.type === "range" || row.type === "nps") return Number(mine) === Number(key)
    if (row.type === "rating") return Number(mine) === Number(key)
    if (row.type === "tap_card" && typeof mine === "object" && typeof key === "string") {
      const [label, choice] = key.split(":")
      return mine[label] === choice
    }
    return String(mine) === String(key)
  }

  _buildBar(label, count, pct, isMine) {
    const row = document.createElement("div")
    row.style.cssText = "display:flex;align-items:center;gap:8px;"

    const lbl = document.createElement("span")
    lbl.style.cssText = `font-family:'ABeeZee',sans-serif;font-size:11px;color:${isMine ? "var(--brand-primary,#01EACB)" : "rgba(255,255,255,0.7)"};min-width:110px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;`
    lbl.title = label
    lbl.textContent = (isMine ? "● " : "") + label
    row.appendChild(lbl)

    const track = document.createElement("div")
    track.style.cssText = "flex:1;height:7px;border-radius:4px;background:rgba(255,255,255,0.06);overflow:hidden;"
    const fill = document.createElement("div")
    fill.style.cssText = `height:100%;border-radius:4px;background:${isMine ? "var(--brand-primary,#01EACB)" : "rgba(255,255,255,0.35)"};width:${pct}%;`
    track.appendChild(fill)
    row.appendChild(track)

    const pctEl = document.createElement("span")
    pctEl.style.cssText = "font-family:'Alata',sans-serif;font-size:10px;color:rgba(255,255,255,0.5);min-width:46px;text-align:right;"
    pctEl.textContent = `${count} (${pct}%)`
    row.appendChild(pctEl)

    return row
  }

  _update() {
    this._clearRequiredHint()
    const total = this.cardTargets.length
    const idx   = this.currentValue
    this.cardTargets.forEach((c, i) => c.classList.toggle("active", i === idx))
    this.progressTarget.textContent = t("player.progress", { n: idx + 1, total })
    this.element.style.setProperty("--player-progress", `${Math.round(((idx + 1) / total) * 100)}%`)
    this.backBtnTarget.classList.remove("hidden")
    this.backBtnTarget.classList.toggle("invisible", idx === 0)
    const isLast = idx === total - 1
    this.nextBtnTarget.classList.toggle("hidden", isLast)
    this.finishBtnTarget.classList.toggle("hidden", !isLast)
  }
}
