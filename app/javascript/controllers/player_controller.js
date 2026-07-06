import { Controller } from "@hotwired/stimulus"
import { t } from "lib/i18n"
import { haptic } from "lib/haptics"

export default class extends Controller {
  static targets = ["card", "backBtn", "nextBtn", "finishBtn", "thankyou", "progress",
                    "thankyouMain", "compareBtn", "comparison", "comparisonList", "comparisonMeta",
                    "regionsBtn", "regionsPanel", "regionsMain", "regionsMeta", "regionsList",
                    "regionDetail", "regionDetailTitle", "regionDetailList", "shareBtn", "requiredHint",
                    "consentMain", "consentDeclined",
                    "scoreChip", "quizScore", "scoresBtn", "scoresPanel", "scoresList", "scoresMeta"]
  static values  = {
    progressUrl: { type: String, default: "" },
    submitUrl: String,
    consentUrl: { type: String, default: "" },
    resultsUrl: { type: String, default: "" },
    regionsUrl: { type: String, default: "" },
    locale: { type: String, default: "" },
    shareUrl: { type: String, default: "" },
    showComparison: { type: Boolean, default: false },
    quiz: { type: Boolean, default: false },
    gradeUrl: { type: String, default: "" },
    quizStateUrl: { type: String, default: "" },
    scoresUrl: { type: String, default: "" },
    current: { type: Number, default: 0 }
  }

  _answers = {}
  _registered = false
  _regionsData = null

  // Quiz state: which card indices have been answered+revealed (so they can't
  // be redone), and the running score.
  _revealed = new Set()
  _quizScore = 0
  _quizMax = 0
  _scoresData = null

  connect() {
    this._sessionToken = this._ensureToken()
    this._nextLabel   = this.hasNextBtnTarget   ? this.nextBtnTarget.textContent   : ""
    this._finishLabel = this.hasFinishBtnTarget ? this.finishBtnTarget.textContent : ""
    this._update()
    if (this.quizValue) this._initQuiz()
  }

  // Consent card (the first card): agreeing advances into the deck; declining
  // swaps in a polite end-state and leaves the respondent on the gate. Both
  // record the event server-side for the audit trail — fire-and-forget, same
  // best-effort philosophy as _saveProgress(), so a network blip never blocks
  // the respondent's tap.
  agreeConsent() {
    haptic()
    this._recordConsent(true)
    this.next()
  }

  declineConsent() {
    this._recordConsent(false)
    if (this.hasConsentMainTarget) this.consentMainTarget.classList.add("hidden")
    if (this.hasConsentDeclinedTarget) this.consentDeclinedTarget.classList.remove("hidden")
  }

  _recordConsent(agreed) {
    if (!this.consentUrlValue) return
    fetch(this.consentUrlValue, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ session_token: this._sessionToken, agreed })
    }).catch(() => { /* best-effort — nothing to retry from here */ })
  }

  next() {
    // Quiz: a graded card reveals right/wrong on the first Next, and only
    // advances on the second — so the player always sees how they did.
    if (this._needsReveal(this.currentValue)) {
      this._capture(this.currentValue)
      if (!this._requireGuard(this.currentValue)) return
      this._gradeCurrent()
      return
    }
    this._capture(this.currentValue)
    if (!this._requireGuard(this.currentValue)) return
    this._saveProgress()
    if (this.currentValue < this.cardTargets.length - 1) {
      haptic()
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

  _payload() {
    return { session_token: this._sessionToken, answers: this._answers, locale: this.localeValue }
  }

  async finish() {
    // Quiz: if the last card is graded and unrevealed, reveal it first; the
    // player presses Finish again to actually submit.
    if (this._needsReveal(this.currentValue)) {
      this._capture(this.currentValue)
      if (!this._requireGuard(this.currentValue)) return
      await this._gradeCurrent()
      return
    }
    this._capture(this.currentValue)
    if (!this._requireGuard(this.currentValue)) return
    haptic([10, 30, 10]) // a little "done" buzz on completion
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
      // Trust the server's final score over the running client tally.
      if (this.quizValue && data && typeof data.score === "number") {
        this._quizScore = data.score
        if (typeof data.max === "number") this._quizMax = data.max
      }
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
    const key = this.cardTargets[idx]?.dataset.cardIndex
    if (key === undefined || key === "") return true // non-answer cards never block
    const a = this._answers[key]
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

  // Answers are keyed by the card's position in @survey.cards (data-card-index),
  // NOT its position among the card targets — the consent card carries no index
  // and is skipped, so prepending it never shifts the answer keys.
  _capture(idx) {
    const card = this.cardTargets[idx]
    if (!card) return
    const key = card.dataset.cardIndex
    if (key === undefined || key === "") return
    const type  = card.dataset.cardType
    const value = this._read(card, type)
    // "Other" is a standalone answer: if the respondent typed free text it
    // replaces any normal selection for this card.
    const other = card.querySelector("[data-other-input]")?.value.trim()
    this._answers[key] = other
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

      case "prioritise": {
        // The ordered canonical labels, top (highest priority) → bottom. Only
        // counts once the respondent has arranged the list.
        const list = card.querySelector(".prioritise-list")
        if (!list || list.dataset.prioritiseTouched !== "true") return null
        return Array.from(list.querySelectorAll(".prioritise-item"))
                    .map(el => this._canonicalOf(el))
                    .filter(v => v !== null)
      }

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
        // Location demographic: a hidden input carries the resolved
        // "CC|Label" the location-search widget picked (see
        // location_search_controller.js) — this is the app's one universal
        // source of region data (see PlayerController#sync_region_from_answers!).
        const loc = card.querySelector(".location-search-value")
        if (loc) return loc.value || null

        // Month+year demographic: two plain numeric fields, not a native
        // <input type="month"> (see _card_component.html.erb) — combine them
        // into the same "YYYY-MM" shape a native month input would have given.
        const month = card.querySelector(".freeform-month")
        if (month) {
          const year = card.querySelector(".freeform-year")
          const m = month.value.trim(), y = year?.value.trim()
          return (m && y && y.length === 4) ? `${y}-${m.padStart(2, "0")}` : null
        }
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
    if (this.quizValue) this._renderQuizScore()
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
    if (row.type === "prioritise" && Array.isArray(mine)) return mine.length ? mine.join(" › ") : "—"
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
    container.style.cssText = "display:flex;flex-direction:column;gap:14px;"

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
    } else if (row.type === "prioritise") {
      // counts[label] = sum of ranks across responders; lower mean = higher
      // priority. Show the aggregate order with each option's average position.
      const total = row.total || 1
      const ranked = Object.entries(counts)
        .map(([label, sumRank]) => ({ label, mean: sumRank / total }))
        .sort((a, b) => a.mean - b.mean)
      const n = ranked.length || 1
      ranked.forEach(({ label, mean }, i) => {
        const pct = Math.round(Math.max(0, Math.min(1, (n - mean + 1) / n)) * 100)
        container.appendChild(this._buildBar(`${i + 1}. ${label}`, `avg ${mean.toFixed(1)}`, pct, false))
      })
      return container
    } else if (row.type === "tap_card") {
      Object.entries(counts).forEach(([label, yn]) => {
        const yes = (yn && yn.yes) || 0, no = (yn && yn.no) || 0, unsure = (yn && yn.unsure) || 0
        const sum = yes + no + unsure || 1
        entries.push([`${label} — Yes`,    yes,    `${label}:yes`,    sum])
        entries.push([`${label} — Unsure`, unsure, `${label}:unsure`, sum])
        entries.push([`${label} — No`,     no,     `${label}:no`,     sum])
      })
    } else {
      // Unordered options (multiple choice, yes/no, …) read best as a ranked
      // chart — most popular first.
      entries = Object.entries(counts)
        .map(([label, n]) => [label, n, label])
        .sort((a, b) => b[1] - a[1])
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
    row.style.cssText = "display:flex;flex-direction:column;gap:5px;"

    // Header: full label (the respondent's choice is dotted + brand-coloured),
    // a prominent percentage, and the raw count.
    const head = document.createElement("div")
    head.style.cssText = "display:flex;align-items:baseline;gap:8px;"

    const lbl = document.createElement("span")
    lbl.style.cssText = `flex:1;min-width:0;font-family:'ABeeZee',sans-serif;font-size:12px;line-height:1.35;color:${isMine ? "var(--brand-primary,#01EACB)" : "rgba(255,255,255,0.82)"};`
    lbl.textContent = (isMine ? "● " : "") + label
    head.appendChild(lbl)

    const pctEl = document.createElement("span")
    pctEl.style.cssText = "flex-shrink:0;font-family:'Alata',sans-serif;font-size:14px;color:#fff;"
    pctEl.textContent = `${pct}%`
    head.appendChild(pctEl)

    const countEl = document.createElement("span")
    countEl.style.cssText = "flex-shrink:0;min-width:22px;text-align:right;font-family:'ABeeZee',sans-serif;font-size:11px;color:rgba(255,255,255,0.4);"
    countEl.textContent = count
    head.appendChild(countEl)
    row.appendChild(head)

    // Thicker track with a fill that animates up from zero on render.
    const track = document.createElement("div")
    track.style.cssText = "height:10px;border-radius:5px;background:rgba(255,255,255,0.07);overflow:hidden;"
    const fill = document.createElement("div")
    fill.style.cssText = `height:100%;border-radius:5px;width:0;transition:width 0.7s cubic-bezier(0.16,1,0.3,1);background:${isMine ? "var(--brand-primary,#01EACB)" : "rgba(255,255,255,0.3)"};`
    track.appendChild(fill)
    row.appendChild(track)
    requestAnimationFrame(() => { fill.style.width = `${pct}%` })

    return row
  }

  _update() {
    this._clearRequiredHint()
    const cards = this.cardTargets
    const idx   = this.currentValue
    cards.forEach((c, i) => c.classList.toggle("active", i === idx))

    const hasConsent = cards[0]?.dataset.cardType === "consent_card"
    const onConsent  = cards[idx]?.dataset.cardType === "consent_card"

    if (onConsent) {
      // The consent gate drives itself (Agree / decline) — hide the deck nav.
      this.progressTarget.textContent = ""
      this.element.style.setProperty("--player-progress", "0%")
      this.backBtnTarget.classList.add("invisible")
      this.nextBtnTarget.classList.add("hidden")
      this.finishBtnTarget.classList.add("hidden")
      return
    }

    // Keep the consent card out of the progress the respondent sees.
    const offset = hasConsent ? 1 : 0
    const total  = cards.length - offset
    const n      = idx + 1 - offset
    this.progressTarget.textContent = t("player.progress", { n, total })
    this.element.style.setProperty("--player-progress", `${Math.round((n / total) * 100)}%`)
    this.backBtnTarget.classList.remove("hidden")
    // Don't allow stepping back onto the consent gate once agreed.
    this.backBtnTarget.classList.toggle("invisible", idx === offset)
    const isLast = idx === cards.length - 1
    this.nextBtnTarget.classList.toggle("hidden", isLast)
    this.finishBtnTarget.classList.toggle("hidden", !isLast)
    if (this.quizValue) this._labelQuizNav()
  }

  // ── Quiz: per-card grading, reveal, lock, running score ──────────────────

  async _initQuiz() {
    this._quizMax = this.cardTargets.filter(c => c.dataset.cardGraded === "true").length
    this._renderScoreChip()

    // Refresh-proof no-redo: re-lock and re-reveal cards this session already
    // committed, server-side (owner preview has no endpoint and starts fresh).
    if (!this.quizStateUrlValue) return
    try {
      const url = `${this.quizStateUrlValue}?session_token=${encodeURIComponent(this._sessionToken)}`
      const res  = await fetch(url, { headers: { "Accept": "application/json" } })
      const data = await res.json()
      if (!data || !data.ok || !data.quiz) return
      if (typeof data.max === "number") this._quizMax = data.max
      Object.entries(data.answered || {}).forEach(([key, info]) => {
        const card = this.cardTargets.find(c => c.dataset.cardIndex === key)
        if (!card) return
        this._answers[key] = { type: card.dataset.cardType, value: info.value }
        this._applyValue(card, card.dataset.cardType, info.value)
        this._revealCard(card, { correct: info.correct, correctAnswer: info.correct_answer,
                                 explanation: info.explanation, mine: info.value })
        this._revealed.add(this.cardTargets.indexOf(card))
      })
      if (typeof data.score === "number") this._quizScore = data.score
      this._renderScoreChip()
      this._update()
    } catch (_) { /* a fresh start is fine if state can't load */ }
  }

  // A card that still needs its quiz reveal before the player can move on.
  _needsReveal(idx) {
    const card = this.cardTargets[idx]
    return this.quizValue && card?.dataset.cardGraded === "true" && !this._revealed.has(idx)
  }

  async _gradeCurrent() {
    const idx  = this.currentValue
    const card = this.cardTargets[idx]
    const key  = card.dataset.cardIndex
    this._revealed.add(idx) // lock now so a double-tap can't re-submit
    card.classList.add("quiz-locking")
    this._setGradingBusy(true)

    const result = this.gradeUrlValue
      ? await this._gradeRemote(key)         // live: server is authoritative
      : this._gradeLocal(card)               // owner preview: embedded answers
    card.classList.remove("quiz-locking")
    this._setGradingBusy(false)
    if (!result) { this._revealed.delete(idx); return } // couldn't grade — allow a retry

    if (typeof result.score === "number") this._quizScore = result.score
    else if (result.correct) this._quizScore++
    if (typeof result.max === "number") this._quizMax = result.max

    this._revealCard(card, result)
    this._renderScoreChip()
    this._update()
    haptic(result.correct ? [12, 24, 12] : 30)
  }

  // Disables Next/Submit and swaps its label while the server checks the
  // answer — a free-text quiz answer can take a couple of seconds now that a
  // close-but-not-exact wording gets an AI judgment call (see
  // QuizAnswerGrader), not just an instant exact-match. Guards against a
  // confused double-tap mid-request.
  _setGradingBusy(busy) {
    const label = busy ? t("player.quiz_grading") : t("player.quiz_check")
    ;[ this.hasNextBtnTarget && this.nextBtnTarget, this.hasFinishBtnTarget && this.finishBtnTarget ]
      .filter(Boolean)
      .forEach(btn => { btn.textContent = label; btn.dataset.disabled = busy ? "true" : "false" })
  }

  async _gradeRemote(key) {
    try {
      const res = await fetch(this.gradeUrlValue, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ ...this._payload(), card_index: Number(key) })
      })
      if (!res.ok) throw new Error(`HTTP ${res.status}`)
      const data = await res.json()
      if (!data.ok || !data.graded) return null
      return { correct: data.correct, correctAnswer: data.correct_answer,
               explanation: data.explanation, score: data.score, max: data.max,
               mine: this._answers[key]?.value }
    } catch (_) { return null }
  }

  _gradeLocal(card) {
    let correct
    try { correct = JSON.parse(card.dataset.cardCorrect || "null") } catch (_) { correct = null }
    if (correct === null || correct === undefined || correct === "" ||
        (Array.isArray(correct) && correct.length === 0)) return null
    const value = this._answers[card.dataset.cardIndex]?.value
    return { correct: this._matchCorrect(card.dataset.cardType, value, correct),
             correctAnswer: correct, explanation: card.dataset.cardExplanation || "", mine: value }
  }

  // Client mirror of QuizGrading#correct? — used ONLY for owner preview, where
  // the correct answers are embedded on the page. Live grading is server-side.
  _matchCorrect(type, value, correct) {
    const norm  = v => String(v ?? "").trim()
    const normT = v => norm(v).toLowerCase().replace(/\s+/g, " ")
    switch (type) {
      case "multiple_choice": case "yes_no": case "select_one_grid":
        return norm(value) === norm(correct)
      case "select_many": case "select_many_grid": {
        const a = new Set((Array.isArray(value) ? value : []).map(norm).filter(Boolean))
        const b = new Set((Array.isArray(correct) ? correct : []).map(norm).filter(Boolean))
        return a.size === b.size && [ ...a ].every(x => b.has(x))
      }
      case "tap_card": {
        if (typeof value !== "object" || !value || typeof correct !== "object" || !correct) return false
        const keys = Object.keys(correct).filter(k => correct[k] === "yes" || correct[k] === "no")
        return keys.length > 0 && keys.every(k => value[k] === correct[k])
      }
      case "range": case "nps": case "rating":
        if (value === null || value === undefined || value === "") return false
        return Number(value) === Number(correct)
      case "open_ended": {
        if (!norm(value)) return false
        return (Array.isArray(correct) ? correct : [ correct ]).map(normT).filter(Boolean).includes(normT(value))
      }
      default: return false
    }
  }

  _revealCard(card, { correct, correctAnswer, explanation, mine }) {
    card.classList.add("quiz-locked", correct ? "quiz-correct" : "quiz-wrong")
    this._lockInputs(card)
    this._tintOptions(card, correctAnswer, mine)

    const host = card.querySelector(".split-right") || card
    let banner = host.querySelector(".quiz-reveal")
    if (!banner) {
      banner = document.createElement("div")
      banner.className = "quiz-reveal"
      host.appendChild(banner)
    }
    banner.classList.toggle("is-correct", !!correct)
    banner.classList.toggle("is-wrong", !correct)
    const parts = [
      `<div class="quiz-reveal-head">${correct ? "✓" : "✗"} ${this._esc(correct ? t("player.quiz_correct") : t("player.quiz_wrong"))}</div>`
    ]
    if (!correct) {
      parts.push(`<div class="quiz-reveal-answer">${this._esc(t("player.quiz_answer"))} ${this._esc(this._formatCorrect(card.dataset.cardType, correctAnswer))}</div>`)
    }
    if (explanation) parts.push(`<div class="quiz-reveal-expl">${this._esc(explanation)}</div>`)
    banner.innerHTML = parts.join("")
  }

  // Tint the correct option(s) green and the player's wrong pick(s) red — for
  // the list/grid/yes-no types whose options carry a canonical label.
  _tintOptions(card, correctAnswer, mine) {
    const items = Array.from(card.querySelectorAll('[data-picker-target="item"]'))
    if (!items.length) return
    const toSet = v => new Set((Array.isArray(v) ? v : [ v ]).map(x => String(x ?? "").trim()).filter(Boolean))
    const right = toSet(correctAnswer), picked = toSet(mine)
    items.forEach(el => {
      const canon = (el.dataset.canonical || "").trim()
      if (right.has(canon)) el.classList.add("opt-correct")
      else if (picked.has(canon)) el.classList.add("opt-wrong")
    })
  }

  // Restore the player's recorded selection when rehydrating a locked card on
  // reload (choice/grid/open/rating); other widgets rely on the reveal banner.
  _applyValue(card, type, value) {
    if (value === null || value === undefined) return
    if ([ "multiple_choice", "yes_no", "select_one_grid", "select_many", "select_many_grid" ].includes(type)) {
      const set = new Set((Array.isArray(value) ? value : [ value ]).map(v => String(v ?? "").trim()))
      card.querySelectorAll('[data-picker-target="item"]').forEach(el => {
        if (set.has((el.dataset.canonical || "").trim())) el.dataset.selected = "true"
      })
    } else if (type === "open_ended") {
      const loc = card.querySelector(".location-search-value")
      if (loc) {
        loc.value = value
        const sep = String(value).indexOf("|")
        const label = sep >= 0 ? String(value).slice(sep + 1) : ""
        if (label) {
          const selected = card.querySelector(".location-search-selected")
          const selectedText = card.querySelector('[data-location-search-target="selectedText"]')
          const input = card.querySelector('[data-location-search-target="input"]')
          if (selected) selected.hidden = false
          if (selectedText) selectedText.textContent = label
          if (input) input.hidden = true
        }
        return
      }
      const month = card.querySelector(".freeform-month")
      if (month) {
        const m = /^(\d{4})-(\d{2})$/.exec(String(value))
        if (m) {
          month.value = m[2]
          const year = card.querySelector(".freeform-year"); if (year) year.value = m[1]
        }
        return
      }
      const el = card.querySelector("textarea, input[type='date']"); if (el) el.value = value
    } else if (type === "rating") {
      card.querySelectorAll(".rating-star").forEach((s, i) => {
        const on = i < Number(value); s.classList.toggle("active", on); s.textContent = on ? "★" : "☆"
      })
    }
  }

  _lockInputs(card) {
    card.querySelectorAll(".choice-list, .choice-grid, .rotate-wrap, .slider-wrap, .nps-slider, .prioritise-list, .rating-wrap, .freeform-wrap, .other-block")
        .forEach(el => { el.style.pointerEvents = "none" })
    card.querySelectorAll("textarea, input, button[data-other-target='btn']").forEach(el => { el.disabled = true })
  }

  _formatCorrect(type, c) {
    if (Array.isArray(c)) return c.join(", ")
    if (c && typeof c === "object") return Object.entries(c).map(([ k, v ]) => `${k}: ${v}`).join(", ")
    if (type === "rating") return `${c} ★`
    return String(c ?? "")
  }

  _renderScoreChip() {
    if (!this.hasScoreChipTarget || !this.quizValue || this._quizMax <= 0) return
    this.scoreChipTarget.classList.remove("hidden")
    this.scoreChipTarget.textContent = t("player.quiz_score", { score: this._quizScore, max: this._quizMax })
  }

  _labelQuizNav() {
    const pending = this._needsReveal(this.currentValue)
    if (this.hasNextBtnTarget)   this.nextBtnTarget.textContent   = pending ? t("player.quiz_check") : this._nextLabel
    if (this.hasFinishBtnTarget) this.finishBtnTarget.textContent = pending ? t("player.quiz_check") : this._finishLabel
  }

  _renderQuizScore() {
    if (!this.hasQuizScoreTarget || this._quizMax <= 0) return
    const pct = Math.round((this._quizScore / this._quizMax) * 100)
    this.quizScoreTarget.classList.remove("hidden")
    this.quizScoreTarget.innerHTML =
      `<div class="quiz-result-label">${this._esc(t("player.quiz_result_label"))}</div>` +
      `<div class="quiz-result-score">${this._quizScore}<span class="quiz-result-max">/${this._quizMax}</span></div>` +
      `<div class="quiz-result-pct">${pct}%</div>`
  }

  // ── Quiz: how you compare (anonymous score distribution) ─────────────────

  async showScores() {
    if (!this.scoresUrlValue || !this.hasScoresPanelTarget) return
    this.thankyouMainTarget.classList.add("hidden")
    if (this.hasComparisonTarget) this.comparisonTarget.classList.add("hidden")
    this.scoresPanelTarget.classList.remove("hidden")
    if (this._scoresData) return this._renderScores(this._scoresData)
    this.scoresMetaTarget.textContent = t("player.compare_loading")
    try {
      const res  = await fetch(this.scoresUrlValue, { headers: { "Accept": "application/json" } })
      const data = await res.json()
      if (!data.ok) throw new Error(data.error || "Failed")
      this._scoresData = data
      this._renderScores(data)
    } catch (_) {
      this.scoresMetaTarget.textContent = t("player.compare_error")
    }
  }

  hideScores() {
    if (this.hasScoresPanelTarget) this.scoresPanelTarget.classList.add("hidden")
    if (this.hasThankyouMainTarget) this.thankyouMainTarget.classList.remove("hidden")
  }

  _renderScores(data) {
    const total = data.total || 0
    const mine  = this._quizScore
    const below = (data.distribution || []).filter(d => d.score < mine).reduce((s, d) => s + d.count, 0)
    const beat  = total > 0 ? Math.round((below / total) * 100) : 0
    this.scoresMetaTarget.textContent = total > 0
      ? t("player.quiz_compare_meta", { score: mine, max: data.max, beat, avg: data.average })
      : t("player.quiz_compare_empty")

    const list = this.scoresListTarget
    list.innerHTML = ""
    ;(data.distribution || []).forEach(d => {
      const pct = total > 0 ? Math.round((d.count / total) * 100) : 0
      list.appendChild(this._buildBar(t("player.quiz_score_bucket", { score: d.score, max: data.max }),
                                      d.count, pct, d.score === mine))
    })
    if ((data.per_question || []).length) {
      const head = document.createElement("div")
      head.style.cssText = "font-family:'Alata',sans-serif;font-size:13px;color:#fff;margin:8px 0 -4px;"
      head.textContent = t("player.quiz_per_question")
      list.appendChild(head)
      data.per_question.forEach(q => list.appendChild(this._buildBar(q.prompt || `#${q.index + 1}`, q.correct, q.pct, false)))
    }
  }

  _esc(s) {
    return String(s ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;")
      .replace(/>/g, "&gt;").replace(/"/g, "&quot;")
  }
}
