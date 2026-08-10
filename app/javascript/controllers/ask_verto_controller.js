import { Controller } from "@hotwired/stimulus"
import { t } from "lib/i18n"

// Ask Verto: the conversation, the NDJSON stream, and the folder panel.
//
// Two jobs that the editor splits across two controllers are together here
// because they are one interaction: a citation chip is both a piece of the
// answer and the handle that opens the folder onto its source. Keeping the
// panel state next to the stream that produces the sources means the chip can
// do that without an event hop.
//
// The panel follows editor_panel_controller exactly — a class on the grid
// (`is-panel-open`), and CSS does the sliding. Nothing here animates anything;
// entrance pops and the thinking flourish are all CSS the app already had.
//
// COLOUR. Each source arrives from the server carrying `accent` (its question
// type's hue) and `brand` (its Verto's own primary). The chip takes the accent
// only — it is too small to carry two signals — and the source card carries
// both. Neither is computed here; the server is the one place that decides.
const DEFAULT_ACCENT = "#8B85FF"

export default class extends Controller {
  static targets = [
    "grid", "feed", "messages", "input", "send", "sourcesFab", "sourceCount", "fabDots",
    "tab", "tabCount", "pane", "sourceList", "detailTitle", "detailBody", "consentBody", "hero"
  ]
  static values = { threadUrl: String, newThreadUrl: String, sources: Array, initialQuestion: String }

  // Sources for the CURRENT answer, keyed by their number. Replaced each turn:
  // the rail describes the answer you are reading, not everything ever fetched.
  _sources = new Map()
  _loading = false

  connect() {
    this._restoreSourcesFromLastAnswer()
    this._askInitialQuestion()
  }

  // A question typed before the thread existed: _startThread() carried it
  // through the create redirect and the server echoed it back on this value,
  // only onto an empty thread. The URL is scrubbed before sending so a reload
  // mid-stream cannot re-ask it.
  _askInitialQuestion() {
    const question = this.hasInitialQuestionValue ? this.initialQuestionValue.trim() : ""
    if (!question) return

    const url = new URL(window.location)
    url.searchParams.delete("q")
    history.replaceState(null, "", url)

    this.inputTarget.value = question
    this.send()
  }

  // ── Composing ───────────────────────────────────────────────────────────
  keydown(event) {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault()
      this.send()
    }
  }

  autogrow() {
    const el = this.inputTarget
    el.style.height = "auto"
    el.style.height = `${Math.min(el.scrollHeight, 96)}px`
  }

  // A suggestion chip is just a pre-filled question — it goes through exactly
  // the same path as anything typed, so there is no second way to ask.
  askSuggestion(event) {
    this.inputTarget.value = event.currentTarget.dataset.question || ""
    this.send()
  }

  send() {
    const text = this.inputTarget.value.trim()
    if (!text || this._loading) return

    // No thread yet (a fresh account): make one, then the page reloads onto it.
    if (!this.threadUrlValue) {
      this._startThread()
      return
    }

    this._loading = true
    this.inputTarget.value = ""
    this.autogrow()
    this.sendTarget.disabled = true

    // The hero is the cold start only — it goes the moment there's a real
    // conversation to read.
    if (this.hasHeroTarget) this.heroTarget.remove()

    this._appendUser(text)
    const body = this._appendAssistant()
    this._sources.clear()
    this._renderSources()

    this._stream(text, body)
  }

  _startThread() {
    const form = document.createElement("form")
    form.method = "post"
    form.action = this.newThreadUrlValue
    const token = document.querySelector('meta[name="csrf-token"]')?.content
    if (token) {
      const input = document.createElement("input")
      input.type = "hidden"
      input.name = "authenticity_token"
      input.value = token
      form.appendChild(input)
    }
    // The composed question rides along — the server hands it back on the new
    // thread's page and _askInitialQuestion() sends it. Without this the first
    // question a fresh account types is silently thrown away by the reload.
    const text = this.inputTarget.value.trim()
    if (text) {
      const q = document.createElement("input")
      q.type = "hidden"
      q.name = "q"
      q.value = text
      form.appendChild(q)
    }
    document.body.appendChild(form)
    form.submit()
  }

  // ── The stream ──────────────────────────────────────────────────────────
  // One JSON object per line. Lines can be split across network chunks, so the
  // tail is held back until a newline arrives.
  async _stream(question, body) {
    // The answer bubble IS a .summary-card: is-generating switches on the 3px
    // rainbow sweep and the teal glow, exactly as the results screen's AI card
    // does, and both drop on the first token rather than on completion.
    body.classList.add("summary-card", "is-generating")
    const rainbow = document.createElement("div")
    rainbow.className = "summary-rainbow"
    body.appendChild(rainbow)

    const steps = this._appendSteps(body)

    try {
      const token = document.querySelector('meta[name="csrf-token"]')?.content
      const res = await fetch(this.threadUrlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          ...(token ? { "X-CSRF-Token": token } : {})
        },
        body: JSON.stringify({ message: question })
      })
      if (!res.ok) throw new Error(`HTTP ${res.status}`)

      const reader = res.body.getReader()
      const decoder = new TextDecoder()
      let pending = ""

      for (;;) {
        const { done, value } = await reader.read()
        if (done) break

        pending += decoder.decode(value, { stream: true })
        const lines = pending.split("\n")
        pending = lines.pop()

        for (const line of lines) {
          if (!line.trim()) continue
          let event
          try {
            event = JSON.parse(line)
          } catch (_) {
            continue
          }
          this._handle(event, body, steps)
        }
      }
    } catch (_) {
      this._settle(body, steps)
      body.appendChild(document.createTextNode(t("ask.error")))
    }

    this._settle(body, steps)
    this._loading = false
    this.sendTarget.disabled = false
    this.inputTarget.focus()
  }

  // Drop the thinking chrome. Idempotent — called on first token, on error and
  // at the end, and the last two may both fire.
  _settle(body, steps) {
    body.classList.remove("is-generating")
    body.querySelector(".summary-rainbow")?.remove()
    steps?.remove()
  }

  _handle(event, body, steps) {
    switch (event.t) {
      case "status":
        this._advanceSteps(steps, event.text)
        break

      case "source":
        this._sources.set(event.source.n, event.source)
        this._renderSources()
        break

      case "token":
        this._settle(body, steps)
        body.appendChild(document.createTextNode(event.text))
        break

      case "cite":
        this._settle(body, steps)
        body.appendChild(this._citeChip(event.n))
        break

      case "quote":
        this._settle(body, steps)
        body.appendChild(this._quoteBlock(event))
        break

      case "warning":
        body.appendChild(this._warning(event.text))
        break

      case "error":
        this._settle(body, steps)
        body.appendChild(document.createTextNode(event.text))
        break

      case "done":
        if (this._sources.size) body.appendChild(this._jumpPill())
        break
    }
    this._scroll()
  }

  // ── Rendering ───────────────────────────────────────────────────────────
  _appendUser(text) {
    const wrap = document.createElement("div")
    wrap.className = "ask-msg-user"
    const bubble = document.createElement("div")
    bubble.className = "b"
    bubble.textContent = text
    wrap.appendChild(bubble)
    this.messagesTarget.appendChild(wrap)
    this._scroll()
  }

  _appendAssistant() {
    const wrap = document.createElement("div")
    wrap.className = "ask-msg-ai"
    const mark = document.createElement("span")
    mark.className = "ask-ai-mark"
    mark.textContent = "✦"
    const body = document.createElement("div")
    body.className = "ask-ai-body"
    wrap.append(mark, body)
    this.messagesTarget.appendChild(wrap)
    this._scroll()
    return body
  }

  // The generating stage's step row: search → read → answer, with the active
  // dot pulsing. Which step is active is driven by the server's status events.
  _appendSteps(body) {
    const row = document.createElement("div")
    row.className = "ask-steps"
    for (const key of ["searching", "reading", "answering"]) {
      const step = document.createElement("span")
      step.className = "ask-step"
      step.dataset.step = key
      step.dataset.state = key === "searching" ? "active" : "idle"
      const dot = document.createElement("span")
      dot.className = "ask-step-dot"
      const label = document.createElement("span")
      label.textContent = t(`ask.${key}`)
      step.append(dot, label)
      row.appendChild(step)
    }
    body.appendChild(row)
    return row
  }

  // The server's status text names the stage; map it onto the row rather than
  // printing it, so the same three steps always appear in the same order.
  _advanceSteps(steps, text) {
    if (!steps) return
    const order = ["searching", "reading", "answering"]
    const lower = (text || "").toLowerCase()
    let current = lower.includes("read") ? 1 : 0
    if (lower.includes("answer") || lower.includes("writ")) current = 2

    order.forEach((key, i) => {
      const el = steps.querySelector(`[data-step="${key}"]`)
      if (!el) return
      el.dataset.state = i < current ? "done" : i === current ? "active" : "idle"
      if (i < current) el.querySelector(".ask-step-dot").textContent = "✓"
    })
  }

  _citeChip(n) {
    const chip = document.createElement("button")
    chip.type = "button"
    chip.className = "ask-cite"
    chip.textContent = n
    chip.dataset.action = "click->ask-verto#openCitation"
    chip.dataset.source = n
    const source = this._sources.get(n)
    if (source) {
      chip.style.setProperty("--cite-accent", source.accent || DEFAULT_ACCENT)
      chip.title = `${source.verto} · ${source.question}`
    }
    return chip
  }

  // The body arrives from the server, printed from the stored record — the model
  // never supplies quote text (see AskVertoChat). textContent, not innerHTML.
  _quoteBlock(event) {
    const quote = document.createElement("blockquote")
    quote.className = "ask-quote"
    quote.textContent = event.body
    if (event.theme) {
      const theme = document.createElement("span")
      theme.className = "theme"
      theme.textContent = event.theme
      quote.appendChild(theme)
    }
    return quote
  }

  _warning(text) {
    const el = document.createElement("div")
    el.className = "ask-warning"
    el.textContent = text
    return el
  }

  // A floating way back to the sources, carrying one dot per source in its
  // type's colour — the mix of evidence, readable without opening anything.
  _jumpPill() {
    const pill = document.createElement("button")
    pill.type = "button"
    pill.className = "ask-jump"
    pill.dataset.action = "click->ask-verto#openSources"
    pill.append(this._dotStack("ask-jump-dot"), document.createTextNode(t("ask.jump_to_sources")))
    return pill
  }

  _dotStack(className) {
    const wrap = document.createElement("span")
    wrap.className = "ask-jump-dots"
    for (const source of this._orderedSources()) {
      const dot = document.createElement("span")
      dot.className = className
      dot.style.setProperty("--dot", source.accent || DEFAULT_ACCENT)
      wrap.appendChild(dot)
    }
    return wrap
  }

  _orderedSources() {
    return [...this._sources.entries()].sort((a, b) => a[0] - b[0]).map(([, s]) => s)
  }

  _scroll() {
    this.feedTarget.scrollTop = this.feedTarget.scrollHeight
  }

  // ── The folder ──────────────────────────────────────────────────────────
  openSources() {
    this.gridTarget.classList.add("is-panel-open")
    this._showPane("sources")
  }

  closePanel() {
    this.gridTarget.classList.remove("is-panel-open")
  }

  showPane(event) {
    this._showPane(event.currentTarget.dataset.pane)
  }

  // A citation chip is the handle: it opens the folder onto its own source.
  openCitation(event) {
    const n = Number(event.currentTarget.dataset.source)
    this.element.querySelectorAll(".ask-cite").forEach((chip) => {
      chip.classList.toggle("is-active", chip === event.currentTarget)
    })
    this.gridTarget.classList.add("is-panel-open")
    this._selectSource(n)
  }

  selectSource(event) {
    this._selectSource(Number(event.currentTarget.dataset.source))
  }

  _showPane(name) {
    this.paneTargets.forEach((pane) => {
      pane.classList.toggle("is-active", pane.dataset.pane === name)
    })
    this.tabTargets.forEach((tab) => {
      const on = tab.dataset.pane === name
      tab.classList.toggle("is-active", on)
      tab.setAttribute("aria-selected", on ? "true" : "false")
    })
  }

  _selectSource(n) {
    const source = this._sources.get(n)
    if (!source) {
      this._showPane("sources")
      return
    }

    this.sourceListTarget.querySelectorAll(".ask-src").forEach((el) => {
      el.classList.toggle("is-active", Number(el.dataset.source) === n)
    })
    this._renderDetail(source)
    this._renderConsent(source)
    this._showPane("detail")
  }

  _renderSources() {
    const count = this._sources.size
    this.sourceCountTarget.textContent = count
    this.tabCountTarget.textContent = count
    this.fabDotsTarget.replaceChildren(...this._dotStack("ask-fab-dot").childNodes)

    this.sourceListTarget.replaceChildren()
    if (count === 0) {
      const empty = document.createElement("p")
      empty.className = "ask-empty"
      empty.textContent = t("ask.no_sources")
      this.sourceListTarget.appendChild(empty)
      return
    }

    this._orderedSources().forEach((source, i) => {
      const card = document.createElement("button")
      card.type = "button"
      card.className = "ask-src"
      card.dataset.source = source.n
      card.dataset.action = "click->ask-verto#selectSource"
      card.style.setProperty("--src-accent", source.accent || DEFAULT_ACCENT)
      // The Verto's own brand colour on the leading edge, so two sources from
      // one study visibly belong together whatever kind of question they are.
      if (source.brand) card.style.setProperty("--verto-brand", source.brand)
      card.style.setProperty("--i", i)

      const icon = document.createElement("span")
      icon.className = "ask-src-icon"
      icon.textContent = source.icon || "◆"

      const main = document.createElement("span")
      main.className = "ask-src-main"

      const head = document.createElement("span")
      head.className = "ask-src-n"
      const num = document.createElement("span")
      num.textContent = source.n
      const who = document.createElement("span")
      who.className = "who"
      who.textContent = `${source.verto} · ${source.organisation}`
      head.append(num, who)

      const question = document.createElement("span")
      question.className = "ask-src-q"
      question.textContent = source.question

      const meta = document.createElement("span")
      meta.className = "ask-src-meta"
      const nEl = document.createElement("span")
      nEl.textContent = `n ${Number(source.responses || 0).toLocaleString()}`
      meta.appendChild(nEl)
      if (source.fielded) {
        const when = document.createElement("span")
        when.textContent = source.fielded
        meta.appendChild(when)
      }
      // Absent on citations stored before SDG tagging existed — the snapshot
      // renders as it was answered, so old sources simply show no SDG entry.
      if (Array.isArray(source.sdgs) && source.sdgs.length > 0) {
        const sdgs = document.createElement("span")
        sdgs.textContent = `SDG ${source.sdgs.join(" · ")}`
        meta.appendChild(sdgs)
      }

      main.append(head, question, meta)
      card.append(icon, main)
      this.sourceListTarget.appendChild(card)
    })
  }

  _renderDetail(source) {
    this.detailTitleTarget.textContent = `${t("ask.detail")} ${source.n}`
    this.detailBodyTarget.replaceChildren()

    const island = document.createElement("div")
    island.className = "ask-island"
    island.style.setProperty("--src-accent", source.accent || DEFAULT_ACCENT)

    const lab = document.createElement("p")
    lab.className = "ask-lab"
    lab.textContent = source.question
    island.appendChild(lab)

    const prov = [
      ["Verto", source.verto],
      ["Org", source.organisation],
      [t("ask.responses"), Number(source.responses || 0).toLocaleString()],
      ["Fielded", source.fielded],
      ["Theme", source.theme],
      // Joins to "" for pre-SDG citation snapshots, which the falsy guard
      // below then skips — old answers honestly show no SDG row.
      ["SDG", (source.sdgs || []).map((n) => `SDG ${n}`).join(", ")]
    ]
    for (const [key, value] of prov) {
      if (!value) continue
      const row = document.createElement("div")
      row.className = "ask-prov-row"
      const k = document.createElement("span")
      k.className = "ask-prov-k"
      k.textContent = key
      const v = document.createElement("span")
      v.className = "ask-prov-v"
      v.textContent = value
      row.append(k, v)
      island.appendChild(row)
    }
    this.detailBodyTarget.appendChild(island)
  }

  // Why this source may be cited at all. Every line here is a fact the server
  // established before the row existed; none of it is inferred in the browser.
  _renderConsent(source) {
    this.consentBodyTarget.replaceChildren()
    const island = document.createElement("div")
    island.className = "ask-island"

    const lab = document.createElement("p")
    lab.className = "ask-lab"
    lab.textContent = `${source.verto} · ${source.organisation}`
    island.appendChild(lab)

    const lines = [
      t("ask.consent_opted_in"),
      t("ask.consent_approved"),
      t("ask.consent_sample"),
      t("ask.consent_aggregates")
    ]
    for (const line of lines) {
      const row = document.createElement("div")
      row.className = "ask-cc-row"
      const ok = document.createElement("span")
      ok.className = "ok"
      ok.textContent = "✓"
      const text = document.createElement("span")
      text.textContent = line
      row.append(ok, text)
      island.appendChild(row)
    }
    this.consentBodyTarget.appendChild(island)
  }

  // A reloaded page renders its answers server-side, so the chips are on the
  // page but the source map isn't. It is hydrated from the stored citations the
  // server serialised into sourcesValue — not scraped from the chips, which
  // carry only an accent and would leave every restored card showing a fallback
  // glyph and a count of zero.
  _restoreSourcesFromLastAnswer() {
    const stored = this.hasSourcesValue ? this.sourcesValue : []
    if (!stored.length) return

    for (const source of stored) {
      if (source && source.n != null) this._sources.set(Number(source.n), source)
    }
    this._renderSources()
  }
}
