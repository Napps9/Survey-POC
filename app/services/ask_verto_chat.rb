# Ask Verto's answer loop: Claude, three corpus tools, and the rule that a figure
# it states must have come back from one of them.
#
# ── Why a tool loop and not a prompt full of data ──────────────────────────────
# The alternative is cheaper: pre-aggregate the corpus into a cached system prompt
# and ask the model to cite. It also cannot be trusted, because "cite your source"
# is an instruction, and an instruction is something a model can follow
# imperfectly. Here the citation is structural — CorpusTools stamps each row it
# returns with a source number, and a marker naming a number that was never
# stamped is removed before anyone reads it. The model cannot cite a Verto it was
# not shown.
#
# ── Two markers ───────────────────────────────────────────────────────────────
#   [[c:3]]   cite source 3 — a question the tools returned this turn.
#   [[q:88]]  show quote 88 — a CorpusQuote id the tools returned this turn.
#
# Quotes are referenced, never reproduced. The model writes [[q:88]] and the
# SERVER prints the stored, redacted body. A model that paraphrases a respondent
# therefore produces a broken reference rather than a plausible misquote, which
# is the only version of "verbatim" worth selling.
#
# ── Streaming shape ───────────────────────────────────────────────────────────
# Tool rounds run non-streaming: their output is data, nobody reads it, and
# streaming tool-call arguments means buffering input_json_delta across content
# blocks — a subtle failure that surfaces as the model querying the wrong
# question rather than as an error. Only the final answer streams, token by
# token, which is the part a person is waiting on.
#
# ── An answer turn that says nothing ──────────────────────────────────────────
# That turn can finish cleanly and generate no text at all — the token budget
# spent on reasoning before a word is written, a refusal, a turn reaching for a
# tool it is not allowed. None of that arrives as an error; it arrives as a
# successful, wordless stream, and everything downstream used to accept it as
# the answer: a blank bubble under a full source rail, and nothing persisted, so
# a reload lost the question too. stream_answer now asks a second time before
# believing it, and finish reports the failure rather than closing on silence.
#
# ── How the loop ends ─────────────────────────────────────────────────────────
# It used to end by noticing that a round came back without tool calls. That
# noticing cost a whole answer: the model had already written ~450 tokens of
# prose, the loop discarded it, and stream_answer generated the same answer
# again. The reader waited through a generation they never saw.
#
# So the rounds run under tool_choice "any" — a round CANNOT write prose — and
# `answer_now` is the move that means "I have enough". A terminating round is
# now ~20 tokens instead of a full answer. Breaking on it appends nothing to
# the conversation, so stream_answer still sees a clean sequence of
# tool_use/tool_result pairs, exactly as before.
#
# `drafted` is the belt to that pair of braces: if a round somehow answers
# anyway, the text is replayed through the same flush! pipeline rather than
# regenerated. Same code path, so the citation check is the same check — a
# second, parallel one is how a guarantee quietly stops holding.
class AskVertoChat
  include AnthropicHelpers

  # The answer is what a person reads, so it stays on the better model. The
  # rounds — pick search words, pick question ids — are a separate ENV knob,
  # defaulted to the same thing. See ClaudeModels::ASK_TOOL_ROUNDS.
  MODEL       = ClaudeModels::DEFAULT
  ROUND_MODEL = ClaudeModels::ASK_TOOL_ROUNDS

  # A round writes a tool call and nothing else (tool_choice "any"), so its
  # ceiling only has to be big enough for one.
  ROUND_MAX_TOKENS = 2000

  # The answer's ceiling sits far above the ~250 words the prompt asks for,
  # because max_tokens bounds EVERYTHING a turn generates — reasoning included.
  # A model that thinks before it writes can spend a 2,000-token ceiling
  # entirely on thinking and end the turn with stop_reason "max_tokens" and not
  # one visible word: a clean, finished, wordless turn, which is what an empty
  # answer bubble looks like from the inside. An unused ceiling costs nothing —
  # only generated tokens are billed — so this is set where truncation stops
  # being plausible rather than where the answer is expected to end.
  ANSWER_MAX_TOKENS = 8000

  # How many times the model may call tools before it has to answer. Each round
  # is a Claude call, so this is the per-message cost ceiling. Four is enough to
  # search, widen a failed search, fetch, and fetch once more.
  MAX_TOOL_ROUNDS = 4

  # How much of a replayed draft is handed over at a time. Only the reader
  # notices this: it is what makes a reused answer arrive like a streamed one
  # rather than landing in a single block.
  DRAFT_CHUNK = 40

  CITE_PATTERN  = /\[\[c:(\d+)\]\]/
  QUOTE_PATTERN = /\[\[q:(\d+)\]\]/
  # Any digit run that isn't part of a marker — used to check that an answer
  # making numeric claims actually cited something.
  FIGURE_PATTERN = /\d/

  SYSTEM = <<~PROMPT.freeze
    You are Ask Verto. You answer questions using real survey data collected
    through Playverto, from surveys ("Vertos") whose creators have agreed to
    share their results and which Verto has approved.

    HOW YOU WORK
    You have no data in front of you. Everything you say about the data must
    come from a tool call in THIS conversation turn. Search first, then fetch
    the questions you want numbers from, then call answer_now and answer.

    USE MORE THAN ONE VERTO
    When more than one Verto has data on the question, use more than one. A
    search tells you how many Vertos matched; where it offered questions from
    several, fetch from at least two and say where they agree and where they
    differ. One study is a finding about one study — if only one Verto covers
    the topic, say so plainly rather than letting it stand for everyone.

    CITING — this is the part that matters most
    Every figure, percentage, count, average or comparison you state must be
    followed by the source marker of the result it came from, written exactly
    like this: [[c:3]] where 3 is the "source" number in the tool result.
    - Never write a marker for a source number you were not given.
    - Never state a number that did not come back from a tool.
    - You may add two percentages from the SAME question (e.g. "somewhat" plus
      "very"), and when you do, say what you added.
    - Never combine numbers from different questions or different Vertos into a
      new figure. Comparing two Vertos' figures side by side is fine; averaging
      or summing them is not.

    QUOTING
    When a tool returns quotes, refer to one by writing [[q:88]] with its quote
    id. Do not retype the respondent's words — the page prints them from the
    record. Never invent, translate or tidy a quote.

    DATE THE DATA
    Anchor results in time, in the answer itself: the first time you use a
    Verto's results, say when they were collected — "research collected in
    2023 found…", "in a survey fielded across 2021 and 2022…". The years come
    from the "fielded" window in the tool result and nowhere else; if a result
    carries no fielded window, say the collection date isn't recorded rather
    than guessing one. When you compare Vertos collected in different years,
    date each one — time may be the explanation.

    PRIORITISE QUESTIONS
    Some results come back as "mean_rank". These are average positions in an
    ordered list, NOT counts, and a LOWER number means a HIGHER priority. Say so
    when you use one. Never describe a mean rank as a number of people.

    BEING HONEST ABOUT THE DATA
    - If the corpus does not hold what was asked, say so plainly and say what it
      does hold instead. Never estimate or extrapolate.
    - Name the limits of what you found: how many Vertos it rests on, which
      countries, and when it was collected. Two surveys in one region is a
      finding about that region, not about the world.
    - If a relevant question exists but you could not get results for it, say
      that rather than answering around it.

    STYLE
    Plain text only — no markdown, no bullet characters, no asterisks. Short
    paragraphs. Lead with the answer, then the evidence. Under 250 words unless
    the question genuinely needs more.
  PROMPT
  SYSTEM_WITH_SAFETY = (SYSTEM + PromptSafety::INSTRUCTION).freeze

  def initialize(api_key: ENV.fetch("ANTHROPIC_API_KEY"))
    @client = build_anthropic_client(api_key)
  end

  # Runs one turn. Yields events as Hashes for the controller to serialise:
  #
  #   { t: "status", text: }    what it is doing, while it does it
  #   { t: "source", source: }  a source, the moment it is fetched
  #   { t: "token",  text: }    a piece of the answer
  #   { t: "cite",   n: }       a citation marker, resolved
  #   { t: "quote",  id:, body:, theme: }  a quote, printed from the record
  #
  # Returns { text:, citations: } for persistence.
  def call(messages:, scope: {}, &emit)
    tools     = CorpusTools.new(scope: scope)
    convo     = Array(messages).map { |m| { role: m[:role] || m["role"], content: m[:content] || m["content"] } }
    seen_quotes = {}
    announced   = Set.new

    drafted = nil
    rounds  = 0
    @turn_started = monotonic
    @ttft_ms      = nil

    MAX_TOOL_ROUNDS.times do |round|
      rounds  = round + 1
      call_at = monotonic
      response = @client.messages.create(
        model:           ROUND_MODEL,
        max_tokens:      ROUND_MAX_TOKENS,
        system:          system_blocks(tools),
        tools:           tools.definitions,
        # A round researches; it does not answer. Without this the model ends
        # the loop by writing a whole answer that is then thrown away.
        tool_choice:     { type: "any" },
        messages:        convo,
        request_options: anthropic_request_options
      )
      log_usage("AskVertoChat", response.usage, model: ROUND_MODEL,
                                                ms: elapsed(call_at), phase: "tool_round_#{rounds}")

      blocks    = Array(response.content)
      tool_uses = blocks.select { |b| tool_use?(b) }

      # tool_choice "any" should make this unreachable. If it happens anyway,
      # keep the prose rather than paying for it twice.
      if tool_uses.empty?
        drafted = text_of(blocks)
        break
      end

      # Anything alongside the sentinel is dropped on purpose. Running it would
      # stamp sources whose numbers the model never gets to see, which is how an
      # answer ends up citing a row it was never shown.
      if tool_uses.any? { |b| name_of(b) == CorpusTools::ANSWER_NOW }
        emit&.call(t: "status", text: "Writing the answer…")
        break
      end

      emit&.call(t: "status", text: status_for(tool_uses, tools))

      convo << { role: "assistant", content: blocks }
      convo << { role: "user", content: tool_uses.map { |b| run_tool(b, tools) } }
      mark_cache_breakpoint!(convo)

      # Announce sources as they land, so the rail fills while the answer is
      # still being written rather than all at once at the end. Which numbers
      # are already announced is tracked here, never flagged on the hash — the
      # same hashes become the persisted citation snapshot, and bookkeeping
      # must not ride into the record.
      tools.sources.each do |source|
        emit&.call(t: "source", source: source) if announced.add?(source["n"])
      end
    end

    result = stream_answer(convo, tools, seen_quotes, drafted: drafted, &emit)
    log_turn(tools, rounds: rounds, ms: elapsed(@turn_started))
    result
  end

  private

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def elapsed(from) = ((monotonic - from) * 1000).round

  # One line per turn, because the two questions asked of this feature — is it
  # quick, and does it use more than one Verto — are both unanswerable from the
  # per-call lines alone. `vertos` is the second one, measured rather than felt.
  def log_turn(tools, rounds:, ms:)
    vertos = tools.sources.map { |s| s["verto"] }.uniq.size
    Rails.logger.info(
      "[AskVerto] turn done rounds=#{rounds} sources=#{tools.sources.size} " \
      "vertos=#{vertos} ttft=#{@ttft_ms || '-'}ms total=#{ms}ms"
    )
  rescue => e
    Rails.logger.warn("[AskVerto] failed to log turn: #{e.class}: #{e.message}")
  end

  # Cache the conversation so far, so the next round re-reads the tool results
  # rather than reprocessing them. Only the newest breakpoint is kept — the API
  # allows four and the system block holds one, so leaving old markers in place
  # would eventually overflow the budget.
  #
  # Note what this does NOT buy: the final stream_raw call sets tool_choice
  # "none" where the rounds set "any", and changing tool_choice invalidates the
  # messages tier. The call the reader is actually waiting on can never read
  # this cache. Do not "fix" that by dropping tool_choice "none" — see
  # stream_answer for why it is there.
  def mark_cache_breakpoint!(convo)
    convo.each do |message|
      Array(message[:content]).each do |block|
        block.delete(:cache_control) if block.is_a?(Hash)
      end
    end

    last = Array(convo.last[:content]).last
    last[:cache_control] = { type: "ephemeral" } if last.is_a?(Hash)
  end

  # The instructions are stable and the coverage line is not, so they are
  # separate blocks and only the first is cached.
  def system_blocks(tools)
    # headline_coverage, not coverage: the countries figure costs a join across
    # the whole responses table, nothing here uses it, and this runs on every
    # call of the turn.
    coverage = tools.headline_coverage
    [
      { type: "text", text: SYSTEM_WITH_SAFETY, cache_control: { type: "ephemeral" } },
      { type: "text", text: <<~SCOPE }
        CORPUS AVAILABLE TO YOU RIGHT NOW
        #{coverage[:vertos]} Vertos, #{coverage[:responses]} responses with answers.
        This is every Verto whose creator has opted in AND which Verto has
        approved. If a survey you would expect is missing, it is because one of
        those two has not happened — say that rather than guessing at its data.
      SCOPE
    ]
  end

  def status_for(tool_uses, _tools)
    names = tool_uses.map { |b| name_of(b).to_s }
    return "Searching the corpus…" if names.include?("search_corpus")
    return "Reading the results…"  if names.intersect?(%w[get_questions get_breakdown])

    "Looking at what data exists…"
  end

  # The text of an assistant turn, ignoring any non-text blocks.
  def text_of(blocks)
    blocks.filter_map do |block|
      type = block.respond_to?(:type) ? block.type : (block[:type] || block["type"])
      next unless type.to_s == "text"

      block.respond_to?(:text) ? block.text : (block[:text] || block["text"])
    end.join
  end

  def run_tool(block, tools)
    name    = name_of(block)
    id      = block.respond_to?(:id) ? block.id : block[:id]
    call_at = monotonic
    content = tools.call(name, deep_stringify(input_of(block))).to_json

    # Size, because that is the thing this feature keeps getting wrong: a
    # fetched question used to carry every one of its segments, and nothing
    # measured the result until it was tens of thousands of tokens paid on
    # every round. Characters rather than tokens — there is no tokenizer here
    # and the trend is the point.
    Rails.logger.info("[AskVerto] tool #{name} -> #{content.length} chars in #{elapsed(call_at)}ms")

    { type: "tool_result", tool_use_id: id, content: content }
  end

  # The final turn, streamed. Markers are resolved as they complete, which means
  # buffering: "[[c:" can arrive in one delta and "3]]" in the next, and emitting
  # the raw text would show the reader the plumbing.
  def stream_answer(convo, tools, seen_quotes, drafted: nil, &emit)
    allowed_sources = tools.sources.to_h { |s| [ s["n"], s ] }
    allowed_quotes  = quote_lookup(tools)

    # A round answered despite tool_choice "any". Replay what it wrote through
    # the same pipeline rather than paying for the same answer twice — the
    # markers still resolve against the same stamped sources, because it is
    # literally the same code doing the resolving.
    if drafted.present?
      buffer = +""
      drafted.chars.each_slice(DRAFT_CHUNK) do |chunk|
        buffer << chunk.join
        flush!(buffer, allowed_sources, allowed_quotes, seen_quotes, &emit)
      end
      flush!(buffer, allowed_sources, allowed_quotes, seen_quotes, final: true, &emit)
      return finish(drafted, allowed_sources, seen_quotes, &emit)
    end

    full = stream_once(convo, tools, allowed_sources, allowed_quotes, seen_quotes,
                       phase: "answer_stream", &emit)

    # A turn that generated no text is not an answer, and from in here there is
    # no telling which of several things it was: the token budget spent on
    # reasoning before a word was written, a refusal, a turn that wanted a tool
    # it is not allowed. They all arrive identically — a clean, finished,
    # wordless turn — and everything downstream used to accept that as an
    # answer: the reader got an empty bubble under a full source rail, and
    # nothing was persisted, so a reload lost the question too.
    #
    # So ask once more, in as many words. One extra call, and only on a turn
    # that produced nothing to pay for.
    if full.blank?
      Rails.logger.warn("[AskVerto] answer turn produced no text " \
                        "(stop_reason=#{@stop_reason || '-'}) — asking again")
      full = stream_once(nudged(convo), tools, allowed_sources, allowed_quotes, seen_quotes,
                         phase: "answer_retry", &emit)
    end

    finish(full, allowed_sources, seen_quotes, &emit)
  end

  # One streamed answer turn: emits its resolved pieces as they complete and
  # returns the raw text it generated, markers and all.
  def stream_once(convo, tools, allowed_sources, allowed_quotes, seen_quotes, phase:, &emit)
    buffer = +""
    full   = +""

    # The convo carries the tool rounds' tool_use/tool_result blocks, and the
    # API rejects those unless the tools they reference are declared — so the
    # definitions ride along even though this call must not use them.
    # tool_choice "none" is the other half: with tools declared, a "final"
    # turn could otherwise answer with another tool call, which this loop
    # would render as an empty answer.
    stream_at = monotonic
    stream = @client.messages.stream_raw(
      model:           MODEL,
      max_tokens:      ANSWER_MAX_TOKENS,
      system:          system_blocks(tools),
      tools:           tools.definitions,
      tool_choice:     { type: "none" },
      messages:        convo,
      request_options: anthropic_request_options
    )

    usage = nil
    final_output = nil
    @stop_reason = nil
    stream.each do |event|
      type = event.type if event.respond_to?(:type)
      case type
      when :message_start
        usage = event.message.usage
      when :message_delta
        final_output = event.usage.output_tokens if event.respond_to?(:usage) && event.usage
        @stop_reason = stop_reason_of(event)
      when :content_block_delta
        delta = event.delta
        next unless delta.respond_to?(:type) && delta.type == :text_delta && delta.text

        buffer << delta.text
        full   << delta.text
        flush!(buffer, allowed_sources, allowed_quotes, seen_quotes, &emit)
      end
    end
    # Whatever is left can no longer be the start of a marker.
    flush!(buffer, allowed_sources, allowed_quotes, seen_quotes, final: true, &emit)
    log_usage("AskVertoChat", usage, model: MODEL, output_tokens: final_output,
                                     ms: elapsed(stream_at), phase: phase)
    # A truncated answer still reaches the reader — half an answer beats none —
    # but this is the only thing that ever says the ceiling above is too low for
    # the model behind CLAUDE_MODEL_DEFAULT, so it says it out loud.
    if @stop_reason.to_s == "max_tokens"
      Rails.logger.warn("[AskVerto] answer hit the #{ANSWER_MAX_TOKENS}-token ceiling (#{full.length} chars written)")
    end

    full
  end

  # Why the stream stopped, as the stream itself reported it. Guarded to the
  # bone: this is a diagnostic, and a diagnostic that raises is worse than one
  # that says "-".
  def stop_reason_of(event)
    delta = event.delta if event.respond_to?(:delta)
    delta.stop_reason if delta.respond_to?(:stop_reason)
  end

  # The retry's whole content: the instruction the wordless turn didn't act on,
  # spelled out as a turn of its own. Consecutive user turns are legal — the API
  # combines them — so this rides on the same conversation, cache breakpoint and
  # all, rather than rebuilding one.
  RETRY_NUDGE = "Write the answer now, as plain text, using only the tool results above. " \
                "Do not call a tool. If those results do not answer the question, say exactly that.".freeze

  def nudged(convo) = convo + [ { role: "user", content: RETRY_NUDGE } ]

  # Emit everything in the buffer that is unambiguously done. A partial marker at
  # the tail is held back until the next delta completes it.
  def flush!(buffer, allowed_sources, allowed_quotes, seen_quotes, final: false, &emit)
    loop do
      match = buffer.match(/\[\[(c|q):(\d+)\]\]/)

      unless match
        # Hold back a tail that could still become a marker.
        keep = final ? 0 : trailing_partial_length(buffer)
        emit_text(buffer.slice!(0, buffer.length - keep), &emit)
        return
      end

      emit_text(buffer.slice!(0, match.begin(0)), &emit)
      buffer.slice!(0, match[0].length)

      if match[1] == "c"
        n = match[2].to_i
        # THE CHECK. A marker naming a source that was never stamped this turn is
        # dropped — silently for the reader, loudly in the log.
        if allowed_sources.key?(n)
          emit&.call(t: "cite", n: n)
        else
          Rails.logger.warn("[AskVerto] dropped fabricated citation marker c:#{n}")
        end
      else
        id = match[2].to_i
        quote = allowed_quotes[id]
        if quote
          seen_quotes[id] = quote
          emit&.call(t: "quote", id: id, body: quote[:body], theme: quote[:theme], source_n: quote[:source_n])
        else
          Rails.logger.warn("[AskVerto] dropped fabricated quote marker q:#{id}")
        end
      end
    end
  end

  # Any prefix of a marker: "[", "[[", "[[c", "[[c:", "[[c:4", "[[c:41]".
  # Anchored at both ends, so ordinary bracketed prose ("[removed]") never
  # matches and is emitted straight away.
  PARTIAL_MARKER = /\A\[(?:\[(?:[cq](?::\d*\]?)?)?)?\z/

  # How many trailing characters must be held back because they could still turn
  # into a marker on the next delta.
  #
  # Longest-first, because a marker's opening "[[" contains a "[" — anchoring on
  # the LAST bracket would test "[c" and conclude the text was safe to emit,
  # which is how the plumbing ends up on the reader's screen.
  MAX_PARTIAL = 10

  def trailing_partial_length(buffer)
    [ buffer.length, MAX_PARTIAL ].min.downto(1) do |n|
      return n if PARTIAL_MARKER.match?(buffer[-n, n])
    end
    0
  end

  # The moment the reader stops waiting. Recorded here rather than at the API's
  # first delta because a delta the buffer holds back (a half-written marker) is
  # not something anyone can read yet.
  def emit_text(text, &emit)
    return if text.blank?

    @ttft_ms ||= elapsed(@turn_started) if @turn_started
    emit&.call(t: "token", text: text)
  end

  # Quote ids the tools handed over this turn, with the body the SERVER will
  # print. Built from the database, never from anything the model wrote.
  def quote_lookup(tools)
    ids = tools.sources.map { |s| s["corpus_question_id"] }
    return {} if ids.empty?

    numbers = tools.sources.to_h { |s| [ s["corpus_question_id"], s["n"] ] }
    CorpusQuote.approved.where(corpus_question_id: ids).each_with_object({}) do |quote, out|
      out[quote.id] = { body: quote.body, theme: quote.theme,
                        source_n: numbers[quote.corpus_question_id] }
    end
  end

  # Close the turn: report which sources were actually used, and flag the case
  # the tool loop cannot prevent — an answer full of numbers and no citations.
  def finish(full, allowed_sources, seen_quotes, &emit)
    # Asked twice, wordless twice. Every reader of this turn treats an empty
    # answer as a finished one — the page renders the bubble, the controller
    # persists nothing — so unless the turn says it failed, what arrives is a
    # blank card under a full rail of sources, which reads as the app having
    # lost the answer rather than never having had one.
    if full.blank?
      Rails.logger.error("[AskVerto] answer turn produced no text twice — reporting it to the reader")
      emit&.call(t: "error", text: I18n.t("ask.chat.error"))
      emit&.call(t: "done", citations: [])
      return { text: "", citations: [], quotes: seen_quotes.values }
    end

    used = full.scan(CITE_PATTERN).flatten.map(&:to_i).uniq.select { |n| allowed_sources.key?(n) }
    citations = used.map { |n| allowed_sources[n] }

    # The rounds are forced (tool_choice "any"), so the model cannot answer
    # mid-loop from its own knowledge. The FINAL turn is free prose, and there
    # it still can: confident writing with no citations passes every other
    # check here. This is the one shape that catches it.
    if citations.empty? && full.match?(FIGURE_PATTERN) && full.length > 120
      Rails.logger.warn("[AskVerto] answer stated figures with no valid citation")
      emit&.call(t: "warning", text: "This answer isn't backed by a source in the corpus — treat its figures with care.")
    end

    # Dating is instructional where citing is structural, so it can drift
    # without anything failing. A cited answer that names none of the years its
    # sources were fielded in still reaches the reader — the source rail shows
    # the window regardless — but the log is what makes the drift visible.
    fielded_years = citations.flat_map { |c| c["fielded"].to_s.scan(/\b\d{4}\b/) }.uniq
    if fielded_years.any? && fielded_years.none? { |year| full.include?(year) }
      Rails.logger.warn("[AskVerto] cited answer named no fielded year (sources span #{fielded_years.join(', ')})")
    end

    emit&.call(t: "done", citations: citations)
    { text: full, citations: citations, quotes: seen_quotes.values }
  end
end
