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
// (`is-panel-open`), and CSS does the sliding. Nothing here animates anything.
export default class extends Controller {
  static targets = [
    "grid", "feed", "messages", "input", "send", "sourcesFab", "sourceCount",
    "tab", "tabCount", "pane", "sourceList", "detailTitle", "detailBody", "consentBody"
  ]
  static values = { threadUrl: String, newThreadUrl: String }

  // Sources for the CURRENT answer, keyed by their number. Replaced each turn:
  // the rail describes the answer you are reading, not everything ever fetched.
  _sources = new Map()
  _loading = false

  connect() {
    this._restoreSourcesFromLastAnswer()
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
    document.body.appendChild(form)
    form.submit()
  }

  // ── The stream ──────────────────────────────────────────────────────────
  // One JSON object per line. Lines can be split across network chunks, so the
  // tail is held back until a newline arrives.
  async _stream(question, body) {
    const status = document.createElement("span")
    status.className = "ask-status"
    status.textContent = t("ask.thinking")
    body.appendChild(status)

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
          this._handle(event, body, status)
        }
      }
    } catch (_) {
      status.remove()
      body.appendChild(document.createTextNode(t("ask.error")))
    }

    status.remove()
    this._loading = false
    this.sendTarget.disabled = false
    this.inputTarget.focus()
  }

  _handle(event, body, status) {
    switch (event.t) {
      case "status":
        status.textContent = event.text
        break

      case "source":
        this._sources.set(event.source.n, event.source)
        this._renderSources()
        break

      case "token":
        status.remove()
        body.appendChild(document.createTextNode(event.text))
        break

      case "cite":
        status.remove()
        body.appendChild(this._citeChip(event.n))
        break

      case "quote":
        status.remove()
        body.appendChild(this._quoteBlock(event))
        break

      case "warning":
        body.appendChild(this._warning(event.text))
        break

      case "error":
        status.remove()
        body.appendChild(document.createTextNode(event.text))
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

  _citeChip(n) {
    const chip = document.createElement("button")
    chip.type = "button"
    chip.className = "ask-cite"
    chip.textContent = n
    chip.dataset.action = "click->ask-verto#openCitation"
    chip.dataset.source = n
    const source = this._sources.get(n)
    if (source) chip.title = `${source.verto} · ${source.question}`
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

    this.sourceListTarget.replaceChildren()
    if (count === 0) {
      const empty = document.createElement("p")
      empty.className = "ask-empty"
      empty.textContent = t("ask.no_sources")
      this.sourceListTarget.appendChild(empty)
      return
    }

    for (const [n, source] of [...this._sources.entries()].sort((a, b) => a[0] - b[0])) {
      const card = document.createElement("button")
      card.type = "button"
      card.className = "ask-src"
      card.dataset.source = n
      card.dataset.action = "click->ask-verto#selectSource"

      const head = document.createElement("div")
      head.className = "ask-src-n"
      const num = document.createElement("span")
      num.textContent = n
      const who = document.createElement("span")
      who.className = "who"
      who.textContent = `${source.verto} · ${source.organisation}`
      head.append(num, who)

      const question = document.createElement("div")
      question.className = "ask-src-q"
      question.textContent = source.question

      const meta = document.createElement("div")
      meta.className = "ask-src-meta"
      const n_el = document.createElement("span")
      n_el.textContent = `n ${source.responses.toLocaleString()}`
      meta.appendChild(n_el)
      if (source.fielded) {
        const when = document.createElement("span")
        when.textContent = source.fielded
        meta.appendChild(when)
      }

      card.append(head, question, meta)
      this.sourceListTarget.appendChild(card)
    }
  }

  _renderDetail(source) {
    this.detailTitleTarget.textContent = `${t("ask.detail")} ${source.n}`
    this.detailBodyTarget.replaceChildren()

    const island = document.createElement("div")
    island.className = "ask-island"
    const lab = document.createElement("p")
    lab.className = "ask-lab"
    lab.textContent = source.question
    island.appendChild(lab)

    const prov = [
      ["Verto", source.verto],
      ["Org", source.organisation],
      [t("ask.responses"), source.responses.toLocaleString()],
      ["Fielded", source.fielded],
      ["Theme", source.theme]
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

  // A reloaded page renders its answers server-side, so the chips exist but the
  // source map doesn't. Rebuild it from the last answer's chips so clicking one
  // still opens something rather than silently doing nothing.
  _restoreSourcesFromLastAnswer() {
    const bodies = this.element.querySelectorAll(".ask-ai-body")
    const last = bodies[bodies.length - 1]
    if (!last) return

    last.querySelectorAll(".ask-cite").forEach((chip) => {
      const n = Number(chip.dataset.source)
      const [verto, question] = (chip.title || " · ").split(" · ")
      this._sources.set(n, { n, verto, question, organisation: "", responses: 0 })
    })
    this._renderSources()
  }
}
