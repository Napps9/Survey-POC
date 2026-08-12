import { Controller } from "@hotwired/stimulus"
import { t } from "lib/i18n"
import { sdgChipText, sdgColor } from "lib/un_sdgs"

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
    "grid", "main", "feed", "messages", "input", "send", "sourcesFab", "sourceCount", "fabDots",
    "tab", "tabCount", "pane", "sourceList", "detailTitle", "detailBody", "consentBody", "hero",
    "railTab", "railPane", "eyebrow", "titlePill", "fabRow", "newChat",
    "submitOverlay", "submitModal", "pickCount", "submitGo"
  ]
  static values = {
    threadUrl: String, newThreadUrl: String, sources: Array, initialQuestion: String,
    greetings: Object, phrases: Array
  }

  // Sources for the CURRENT answer, keyed by their number. Replaced each turn:
  // the rail describes the answer you are reading, not everything ever fetched.
  _sources = new Map()
  _loading = false

  connect() {
    // No speechSynthesis, no listen buttons — CSS hides them off this class.
    if (!window.speechSynthesis) this.element.classList.add("no-speech")
    this._restoreSourcesFromLastAnswer()
    this._startEyebrow()
    this._askInitialQuestion()
  }

  disconnect() {
    clearInterval(this._eyebrowTimer)
    window.speechSynthesis?.cancel()
  }

  // ── The rotating eyebrow ────────────────────────────────────────────────
  // Opens with a time-aware greeting — picked by the CLIENT's clock, so
  // "Good morning" tracks the reader, not the server — then cycles the brand
  // phrases with a soft fade-up. Under prefers-reduced-motion it holds still
  // on the greeting.
  _startEyebrow() {
    if (!this.hasEyebrowTarget) return

    const hour = new Date().getHours()
    const greetings = this.hasGreetingsValue ? this.greetingsValue : {}
    const greeting = greetings[hour < 12 ? "morning" : hour < 18 ? "afternoon" : "evening"]
    const phrases = [greeting, ...(this.hasPhrasesValue ? this.phrasesValue : [])].filter(Boolean)
    if (!phrases.length) return

    this.eyebrowTarget.textContent = phrases[0]
    if (phrases.length < 2) return
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return

    let index = 0
    this._eyebrowTimer = setInterval(() => {
      index = (index + 1) % phrases.length
      const el = this.eyebrowTarget
      el.classList.add("is-out")
      setTimeout(() => {
        el.textContent = phrases[index]
        el.classList.remove("is-out")
        el.classList.add("is-in")
        void el.offsetWidth // commit the below-the-line start before releasing it
        el.classList.remove("is-in")
      }, 300)
    }, 3400)
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

    this._leaveColdStart(text)

    this._appendUser(text)
    const body = this._appendAssistant()
    this._sources.clear()
    this._renderSources()

    this._stream(text, body)
  }

  // The hero is the cold start only — it goes the moment there's a real
  // conversation to read. Its composer survives: the same node docks to the
  // bottom (the server renders it docked on a reloaded conversation), and the
  // thread's first question becomes the floating title pill, exactly as
  // AskThread#display_title will name it after the reload.
  _leaveColdStart(question) {
    if (this.hasTitlePillTarget && this.titlePillTarget.hidden) {
      this.titlePillTarget.textContent = question.length > 60 ? `${question.slice(0, 57)}…` : question
      this.titlePillTarget.hidden = false
    }
    // The way out of the conversation appears with the conversation.
    if (this.hasNewChatTarget) this.newChatTarget.hidden = false
    if (!this.hasHeroTarget) return

    clearInterval(this._eyebrowTimer)
    if (this.hasFabRowTarget && this.hasMainTarget) {
      this.fabRowTarget.classList.add("ask-fab-row--docked")
      this.mainTarget.appendChild(this.fabRowTarget)
    }
    this.heroTarget.remove()
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
  //
  // Everything, prelude included, runs inside the try: send() fires this
  // without awaiting it, so a throw anywhere outside it would be an unhandled
  // rejection that leaves _loading stuck true and the composer dead.
  async _stream(question, body) {
    let steps = null
    const state = { terminal: false, contentful: false, text: "" }

    try {
      // The answer bubble IS a .summary-card: is-generating switches on the 3px
      // rainbow sweep and the teal glow, exactly as the results screen's AI card
      // does, and both drop on the first token rather than on completion.
      body.classList.add("summary-card", "is-generating")
      const rainbow = document.createElement("div")
      rainbow.className = "summary-rainbow"
      body.appendChild(rainbow)

      steps = this._appendSteps(body)

      const token = document.querySelector('meta[name="csrf-token"]')?.content
      const res = await fetch(this.threadUrlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          ...(token ? { "X-CSRF-Token": token } : {})
        },
        body: JSON.stringify({ message: question })
      })
      // A followed redirect means the session is gone: the 200 is a login
      // page, and reading it as events would end as a silently empty answer.
      if (res.redirected) throw new Error("redirected")
      if (!res.ok) throw await this._refusal(res)

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
          this._handle(event, body, steps, state)
        }
      }

      // A close with neither a terminal event nor any content is a failure the
      // server could not report — a killed stream, a zero-byte response. A
      // stream that already showed text stands as a partial answer instead.
      if (!state.terminal && !state.contentful) throw new Error("empty stream")
    } catch (err) {
      this._settle(body, steps)
      body.appendChild(document.createTextNode(err?.display || t("ask.error")))
    } finally {
      this._settle(body, steps)
      body.classList.remove("is-streaming")
      this._loading = false
      // Mirrors the input, so a composer the server rendered disabled stays so.
      this.sendTarget.disabled = this.inputTarget.disabled
      this.inputTarget.focus()
    }
  }

  // A refusal with a plain-text body is the server explaining itself — the
  // hourly throttle, the daily cap, the busy stream slot. Those words beat the
  // generic apology; anything else (an HTML error page) falls through to it.
  async _refusal(res) {
    const err = new Error(`HTTP ${res.status}`)
    if ((res.headers.get("Content-Type") || "").startsWith("text/plain")) {
      const text = (await res.text()).trim()
      if (text) err.display = text
    }
    return err
  }

  // Drop the thinking chrome. Idempotent — called on first token, on error and
  // at the end, and the last two may both fire.
  _settle(body, steps) {
    body.classList.remove("is-generating")
    body.querySelector(".summary-rainbow")?.remove()
    steps?.remove()
  }

  // `state` is _stream's ledger of what actually arrived: `contentful` once any
  // of the answer itself has been shown, `terminal` once the server closed the
  // turn deliberately — the difference between a finished stream and a killed one.
  _handle(event, body, steps, state) {
    switch (event.t) {
      case "status":
        this._advanceSteps(steps, event.text)
        break

      case "source":
        this._sources.set(event.source.n, event.source)
        this._renderSources()
        break

      case "token": {
        state.contentful = true
        state.text += event.text
        this._settle(body, steps)
        // A span per chunk, not a bare text node: the fade-up on .ask-token is
        // what makes the answer read as being written. The caret rides on the
        // bubble while the stream is open; _stream's finally lifts it.
        body.classList.add("is-streaming")
        const chunk = document.createElement("span")
        chunk.className = "ask-token"
        chunk.textContent = event.text
        body.appendChild(chunk)
        break
      }

      case "cite":
        state.contentful = true
        this._settle(body, steps)
        body.appendChild(this._citeChip(event.n))
        break

      case "quote":
        state.contentful = true
        this._settle(body, steps)
        body.appendChild(this._quoteBlock(event))
        break

      case "warning":
        body.appendChild(this._warning(event.text))
        break

      case "error":
        state.terminal = true
        this._settle(body, steps)
        body.appendChild(document.createTextNode(event.text))
        break

      case "done":
        state.terminal = true
        body.classList.remove("is-streaming")
        if (this._sources.size) body.appendChild(this._jumpPill())
        if (state.text.trim()) body.appendChild(this._answerTools(state.text))
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
    // Forced: asking a question always snaps the feed to the fresh exchange,
    // wherever the reader had scrolled to before.
    this._scroll(true)
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

  // Follow the stream only while the reader is already at the bottom. Forcing
  // every event to the bottom would snatch the feed back from someone who
  // scrolled up to reread an earlier answer mid-stream.
  _scroll(force = false) {
    const el = this.feedTarget
    const nearBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 120
    if (force || nearBottom) el.scrollTop = el.scrollHeight
  }

  // ── Listen ──────────────────────────────────────────────────────────────
  // The browser's own voice (SpeechSynthesis) — no audio leaves the device and
  // nothing is sent anywhere. The text comes from data-speech-text: the
  // answer's prose without markers, set by the server on replayed answers and
  // from the accumulated stream on live ones, so the voice never reads chrome.
  toggleSpeech(event) {
    const synth = window.speechSynthesis
    if (!synth) return
    const button = event.currentTarget
    const wasSpeaking = button.classList.contains("is-speaking")

    // One voice at a time: whatever was being read stops before anything else
    // happens — including when the same button is asked to stop.
    synth.cancel()
    this._clearSpeaking()
    if (wasSpeaking) return

    const utterance = new SpeechSynthesisUtterance(button.dataset.speechText || "")
    utterance.lang = document.documentElement.lang || "en"
    utterance.onend = utterance.onerror = () => this._clearSpeaking()
    button.classList.add("is-speaking")
    button.setAttribute("aria-label", t("ask.listen_stop"))
    button.title = t("ask.listen_stop")
    synth.speak(utterance)
  }

  _clearSpeaking() {
    this.element.querySelectorAll(".ask-listen.is-speaking").forEach((button) => {
      button.classList.remove("is-speaking")
      button.setAttribute("aria-label", t("ask.listen"))
      button.title = t("ask.listen")
    })
  }

  // The same control the server renders under a replayed answer, built for a
  // just-streamed one.
  _answerTools(text) {
    const row = document.createElement("div")
    row.className = "ask-answer-tools"
    const button = document.createElement("button")
    button.type = "button"
    button.className = "ask-listen"
    button.dataset.action = "click->ask-verto#toggleSpeech"
    button.dataset.speechText = text.trim()
    button.setAttribute("aria-label", t("ask.listen"))
    button.title = t("ask.listen")
    button.innerHTML = '<svg width="12" height="12" viewBox="0 0 16 16" fill="none" aria-hidden="true">' +
      '<path d="M2.5 6v4h2.8L9 13V3L5.3 6H2.5z" fill="currentColor"/>' +
      '<path d="M11 5.5a3.4 3.4 0 0 1 0 5M12.8 3.7a6 6 0 0 1 0 8.6" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/></svg>'
    button.appendChild(document.createTextNode(t("ask.listen")))
    row.appendChild(button)
    return row
  }

  // ── The left folder: scope + threads ────────────────────────────────────
  // Same trick as the sources folder: one class on the grid, CSS does the
  // sliding. The handle pill hides itself while the folder is out (CSS).
  openRail() {
    this.gridTarget.classList.add("is-rail-open")
  }

  closeRail() {
    this.gridTarget.classList.remove("is-rail-open")
  }

  showRailPane(event) {
    const name = event.currentTarget.dataset.lpane
    this.railPaneTargets.forEach((pane) => {
      pane.classList.toggle("is-active", pane.dataset.lpane === name)
    })
    this.railTabTargets.forEach((tab) => {
      const on = tab.dataset.lpane === name
      tab.classList.toggle("is-active", on)
      tab.setAttribute("aria-selected", on ? "true" : "false")
    })
  }

  // ── The submit-your-data picker ─────────────────────────────────────────
  // A plain form of real checkboxes; this only adds the conveniences — the
  // Verto-level tick-all, the parent's checked/partial state, and the live
  // counter. The server re-derives everything the form claims.
  openSubmit() {
    this.submitOverlayTarget.classList.add("is-open")
  }

  closeSubmit() {
    this.submitOverlayTarget.classList.remove("is-open")
    // After a submission the URL carries ?submitted=N so the redirect lands
    // on the success pane; scrub it so a reload doesn't replay the modal.
    const url = new URL(window.location)
    if (url.searchParams.has("submitted")) {
      url.searchParams.delete("submitted")
      history.replaceState(null, "", url)
      this.submitModalTarget.classList.remove("is-done")
    }
  }

  overlayClose(event) {
    if (event.target === this.submitOverlayTarget) this.closeSubmit()
  }

  // The Verto row ticks (or unticks) every set beneath it.
  togglePick(event) {
    const group = event.currentTarget.closest(".ask-pick-group")
    const boxes = [...group.querySelectorAll(".ask-set input[type=checkbox]")]
    const all = boxes.every((box) => box.checked)
    boxes.forEach((box) => { box.checked = !all })
    this.refreshPicks()
  }

  refreshPicks() {
    let questions = 0, questionsOf = 0, responses = 0, vertos = 0

    this.submitOverlayTarget.querySelectorAll(".ask-pick-group").forEach((group) => {
      const boxes = [...group.querySelectorAll(".ask-set input[type=checkbox]")]
      const on = boxes.filter((box) => box.checked)
      boxes.forEach((box) => box.closest(".ask-set").classList.toggle("is-checked", box.checked))

      const parent = group.querySelector(".ask-pick")
      parent.classList.toggle("is-checked", boxes.length > 0 && on.length === boxes.length)
      parent.classList.toggle("is-partial", on.length > 0 && on.length < boxes.length)

      if (on.length) {
        vertos += 1
        responses += Number(boxes[0].dataset.n || 0)
        boxes.forEach((box) => { questionsOf += Number(box.dataset.q || 0) })
        on.forEach((box) => { questions += Number(box.dataset.q || 0) })
      }
    })

    this.submitGoTarget.disabled = vertos === 0
    this.pickCountTarget.textContent = vertos === 0
      ? t("ask.picker_none")
      : t("ask.picker_count", {
          questions, total: questionsOf, responses: responses.toLocaleString()
        })
  }

  // ── The sources folder ──────────────────────────────────────────────────
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

      // Plain language, not survey shorthand: "12,304 people answered ·
      // asked Jan – Jun 2025", with the UN goals as named, colour-coded chips.
      const meta = document.createElement("span")
      meta.className = "ask-src-meta"
      const nEl = document.createElement("span")
      nEl.textContent = t("ask.people_answered", { count: Number(source.responses || 0).toLocaleString() })
      meta.appendChild(nEl)
      if (source.fielded) {
        const when = document.createElement("span")
        when.textContent = t("ask.asked_window", { window: source.fielded })
        meta.appendChild(when)
      }

      main.append(head, question, meta)
      // Absent on citations stored before SDG tagging existed — the snapshot
      // renders as it was answered, so old sources simply show no SDG chips.
      const sdgRow = this._sdgChips(source)
      if (sdgRow) main.appendChild(sdgRow)
      card.append(icon, main)
      this.sourceListTarget.appendChild(card)
    })
  }

  // Named, colour-coded SDG chips — each goal in its official UN colour, with
  // its official (untranslated) title. Returns null when the snapshot carries
  // no goals, so old citations honestly show nothing.
  _sdgChips(source) {
    const numbers = Array.isArray(source.sdgs) ? source.sdgs : []
    if (!numbers.length) return null

    const row = document.createElement("span")
    row.className = "ask-src-sdgs"
    for (const n of numbers) {
      const chip = document.createElement("span")
      chip.className = "ask-sdg-chip"
      chip.style.setProperty("--sdg", sdgColor(n))
      const dot = document.createElement("i")
      chip.append(dot, document.createTextNode(sdgChipText(n)))
      row.appendChild(chip)
    }
    return row
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
      ["SDG", (source.sdgs || []).map((n) => sdgChipText(n)).join(", ")]
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

    // The answer breakdown: every option (or theme) with its share, as bars
    // in the source's own accent. Stamped server-side onto the citation
    // snapshot — a pre-breakdown snapshot simply shows no bars.
    const breakdown = Array.isArray(source.breakdown) ? source.breakdown : []
    if (breakdown.length) {
      const bars = document.createElement("div")
      bars.className = "ask-island"
      bars.style.setProperty("--src-accent", source.accent || DEFAULT_ACCENT)

      const barsLab = document.createElement("p")
      barsLab.className = "ask-lab"
      barsLab.textContent = t("ask.breakdown")
      bars.appendChild(barsLab)

      const list = document.createElement("div")
      list.className = "ask-bars"
      for (const row of breakdown) {
        const item = document.createElement("div")
        item.className = "ask-bar-row"
        const label = document.createElement("span")
        label.className = "ask-bar-lab"
        label.textContent = row.label
        const val = document.createElement("span")
        val.className = "ask-bar-val"
        val.textContent = `${Number(row.percent) || 0}% · ${Number(row.count || 0).toLocaleString()}`
        const track = document.createElement("div")
        track.className = "ask-bar-track"
        const fill = document.createElement("div")
        fill.className = "ask-bar-fill"
        fill.style.width = `${Math.min(Number(row.percent) || 0, 100)}%`
        track.appendChild(fill)
        item.append(label, val, track)
        list.appendChild(item)
      }
      bars.appendChild(list)
      this.detailBodyTarget.appendChild(bars)
    }
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
