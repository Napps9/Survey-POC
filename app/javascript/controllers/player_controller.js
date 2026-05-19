import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["card", "backBtn", "nextBtn", "finishBtn", "thankyou", "progress",
                    "thankyouMain", "compareBtn", "comparison", "comparisonList", "comparisonMeta"]
  static values  = {
    submitUrl: String,
    resultsUrl: { type: String, default: "" },
    showComparison: { type: Boolean, default: false },
    current: { type: Number, default: 0 }
  }

  _answers = {}

  connect() { this._update() }

  next() {
    this._capture(this.currentValue)
    if (this.currentValue < this.cardTargets.length - 1) {
      this.currentValue++
      this._update()
    }
  }

  back() {
    this._capture(this.currentValue)
    if (this.currentValue > 0) {
      this.currentValue--
      this._update()
    }
  }

  async finish() {
    this._capture(this.currentValue)
    const sessionToken = (typeof crypto !== "undefined" && crypto.randomUUID)
      ? crypto.randomUUID()
      : Math.random().toString(36).slice(2)
    let queued = false
    try {
      const res = await fetch(this.submitUrlValue, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ session_token: sessionToken, answers: this._answers })
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

  _capture(idx) {
    const card = this.cardTargets[idx]
    if (!card) return
    const type   = card.dataset.cardType
    const value  = this._read(card, type)
    this._answers[String(idx)] = { type, value }
  }

  _read(card, type) {
    switch (type) {
      case "multiple_choice":
      case "yes_no":
        return card.querySelector('[data-selected="true"] .pick-text')
                   ?.textContent.trim() ?? null

      case "select_many":
        return Array.from(card.querySelectorAll('[data-selected="true"] .pick-text'))
                    .map(e => e.textContent.trim())

      case "select_one_grid":
        return card.querySelector('[data-selected="true"] .choice-label')
                   ?.textContent.trim() ?? null

      case "select_many_grid":
        return Array.from(card.querySelectorAll('[data-selected="true"] .choice-label'))
                    .map(e => e.textContent.trim())

      case "range": {
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

      case "open_ended":
        return card.querySelector("textarea")?.value?.trim() || null

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
      pill.textContent = "Saved — will sync when you're back online"
      this.thankyouMainTarget.appendChild(pill)
    }
  }

  async showComparison() {
    if (!this.showComparisonValue || !this.resultsUrlValue) return
    if (this.hasCompareBtnTarget) {
      this.compareBtnTarget.disabled = true
      this.compareBtnTarget.textContent = "Loading…"
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
        this.compareBtnTarget.textContent = "Couldn't load — try again"
      }
    }
  }

  hideComparison() {
    if (this.hasComparisonTarget) this.comparisonTarget.classList.add("hidden")
    if (this.hasThankyouMainTarget) this.thankyouMainTarget.classList.remove("hidden")
    if (this.hasCompareBtnTarget) {
      this.compareBtnTarget.disabled = false
      this.compareBtnTarget.textContent = "See your results compared to others →"
    }
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
    yourPill.style.cssText = "display:inline-block;padding:4px 10px;border-radius:100px;background:rgba(1,234,203,0.15);color:#01EACB;font-family:'ABeeZee',sans-serif;font-size:11px;margin-bottom:10px;"
    yourPill.textContent = `Your answer: ${this._formatMine(mine, row)}`
    wrap.appendChild(yourPill)

    const body = this._buildDistribution(row, mine)
    if (body) wrap.appendChild(body)

    return wrap
  }

  _formatMine(mine, row) {
    if (mine === null || mine === undefined || mine === "") return "—"
    if (Array.isArray(mine)) return mine.length ? mine.join(", ") : "—"
    if (row.type === "range" && Array.isArray(row.options)) {
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

    if (row.type === "range" && Array.isArray(row.options)) {
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
    if (row.type === "range") return Number(mine) === Number(key)
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
    lbl.style.cssText = `font-family:'ABeeZee',sans-serif;font-size:11px;color:${isMine ? "#01EACB" : "rgba(255,255,255,0.7)"};min-width:110px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;`
    lbl.title = label
    lbl.textContent = (isMine ? "● " : "") + label
    row.appendChild(lbl)

    const track = document.createElement("div")
    track.style.cssText = "flex:1;height:7px;border-radius:4px;background:rgba(255,255,255,0.06);overflow:hidden;"
    const fill = document.createElement("div")
    fill.style.cssText = `height:100%;border-radius:4px;background:${isMine ? "#01EACB" : "rgba(255,255,255,0.35)"};width:${pct}%;`
    track.appendChild(fill)
    row.appendChild(track)

    const pctEl = document.createElement("span")
    pctEl.style.cssText = "font-family:'Alata',sans-serif;font-size:10px;color:rgba(255,255,255,0.5);min-width:46px;text-align:right;"
    pctEl.textContent = `${count} (${pct}%)`
    row.appendChild(pctEl)

    return row
  }

  _update() {
    const total = this.cardTargets.length
    const idx   = this.currentValue
    this.cardTargets.forEach((c, i) => c.classList.toggle("active", i === idx))
    this.progressTarget.textContent = `Card ${idx + 1} of ${total}`
    this.element.style.setProperty("--player-progress", `${Math.round(((idx + 1) / total) * 100)}%`)
    this.backBtnTarget.classList.remove("hidden")
    this.backBtnTarget.classList.toggle("invisible", idx === 0)
    const isLast = idx === total - 1
    this.nextBtnTarget.classList.toggle("hidden", isLast)
    this.finishBtnTarget.classList.toggle("hidden", !isLast)
  }
}
