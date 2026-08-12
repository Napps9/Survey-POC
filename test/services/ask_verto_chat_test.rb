require "test_helper"
require "ostruct"

# The citation guarantee.
#
# Everything else in Ask Verto exists to make these assertions possible: that a
# figure the model states came back from a tool, that a source it names was one
# it was handed, and that a quote it shows is the respondent's stored words and
# not the model's rendering of them.
#
# The client is stubbed throughout — the point is what the service does with what
# a model returns, including when what it returns is wrong.
class AskVertoChatTest < ActiveSupport::TestCase
  # A client that plays a scripted sequence: each entry is either a list of
  # tool_use blocks (a tool round) or a string (the final answer, streamed a few
  # characters at a time so marker-splitting across deltas is exercised).
  class ScriptedClient
    attr_reader :calls

    def initialize(script)
      @script = script.dup
      @calls  = []
    end

    def messages = self

    def create(**kwargs)
      @calls << kwargs.merge(op: :create)
      step = @script.first
      if step.is_a?(Array)
        @script.shift
        OpenStruct.new(content: step.map.with_index { |s, i|
          OpenStruct.new(type: "tool_use", id: "tu_#{i}", name: s[:name], input: s[:input])
        }, usage: usage)
      else
        OpenStruct.new(content: [ OpenStruct.new(type: "text", text: "") ], usage: usage)
      end
    end

    def stream_raw(**kwargs)
      @calls << kwargs.merge(op: :stream_raw)
      text = @script.find { |s| s.is_a?(String) } || ""
      events = [ OpenStruct.new(type: :message_start, message: OpenStruct.new(usage: usage)) ]
      # Three characters at a time, so "[[c:1]]" is guaranteed to straddle deltas.
      text.chars.each_slice(3) do |chunk|
        events << OpenStruct.new(type: :content_block_delta,
                                 delta: OpenStruct.new(type: :text_delta, text: chunk.join))
      end
      events << OpenStruct.new(type: :message_delta, usage: OpenStruct.new(output_tokens: 20))
      events
    end

    def usage
      OpenStruct.new(input_tokens: 10, output_tokens: 5,
                     cache_creation_input_tokens: 0, cache_read_input_tokens: 0)
    end
  end

  def setup
    @org = Organisation.create!(name: "Anglo American Foundation", slug: "avc-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(
      title: "Valparaíso Youth Pulse", theme: "Climate Action", audience_age: "all",
      key_insight: "x", default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "multiple_choice", "cid" => "c_w", "text" => "How worried are you about climate change?",
                 "options" => [ "Very worried", "Somewhat worried", "Not worried" ] },
               { "type" => "open_ended", "cid" => "c_d", "text" => "What do you dream about?" } ]
    )
    40.times do |i|
      @survey.responses.create!(session_token: SecureRandom.hex(8), status: "completed",
                                answers: { "0" => { "value" => i < 30 ? "Very worried" : "Not worried" },
                                           "1" => { "value" => "I dream of a city where the air is clean and people care" } })
    end
    @entry = CorpusEntry.create!(survey: @survey, organisation: @org,
                                 review_status: "approved", opted_in_at: 1.day.ago)
    CorpusIndexer.new(@entry, themer: stub_themer).call
    @question = @entry.corpus_questions.find_by(cid: "c_w")
  end

  # Themes come from Claude; here they are canned so the corpus has a quote to
  # reference without a second stubbed client.
  def stub_themer
    Class.new do
      def call(texts:, **)
        { themes: [ { "label" => "collective agency", "count" => 40 } ],
          quotes: [ { body: texts.first, theme: "collective agency" } ] }
      end
    end.new
  end

  def run_chat(script, question: "Are young people worried about climate change?")
    chat = AskVertoChat.allocate
    chat.instance_variable_set(:@client, ScriptedClient.new(script))
    events = []
    result = chat.call(messages: [ { role: "user", content: question } ]) { |e| events << e }
    [ result, events ]
  end

  def text_of(events) = events.select { |e| e[:t] == "token" }.map { |e| e[:text] }.join

  def fetch_step = [ { name: "get_questions", input: { "ids" => [ @question.id ] } } ]

  # ── The guarantee ─────────────────────────────────────────────────────────
  test "a citation marker for a source that was never fetched is removed" do
    _result, events = run_chat([
      fetch_step,
      "Worry is high [[c:1]] and a different survey agrees [[c:7]]."
    ])

    cites = events.select { |e| e[:t] == "cite" }.map { |e| e[:n] }
    assert_equal [ 1 ], cites, "source 7 was never stamped; it must not reach the reader"
    assert_not_includes text_of(events), "[[c:7]]", "the raw marker must never be shown either"
    assert_not_includes text_of(events), "[[c:1]]"
  end

  test "a fabricated citation is not persisted as a source" do
    result, = run_chat([ fetch_step, "Everything is fine [[c:9]]." ])

    assert_empty result[:citations]
  end

  test "a valid citation resolves to the row it points at" do
    result, events = run_chat([ fetch_step, "75% are very worried [[c:1]]." ])

    assert_equal 1, result[:citations].size
    citation = result[:citations].first
    assert_equal @question.id, citation["corpus_question_id"]
    assert_equal "Valparaíso Youth Pulse", citation["verto"]
    assert_equal "Anglo American Foundation", citation["organisation"]
    assert_equal 40, citation["responses"]
    assert_equal "75% are very worried .", text_of(events)
  end

  test "markers split across streaming deltas are still resolved" do
    # The scripted client emits three characters at a time, so "[[c:1]]" always
    # straddles at least two deltas — the case that would otherwise leak plumbing
    # into the reader's view.
    _result, events = run_chat([ fetch_step, "A" * 40 + "[[c:1]]" + "B" * 40 ])

    assert_equal 1, events.count { |e| e[:t] == "cite" }
    assert_equal ("A" * 40) + ("B" * 40), text_of(events)
  end

  test "ordinary square brackets in prose are not eaten" do
    _result, events = run_chat([ fetch_step, "The answer [removed] stays as written." ])

    assert_equal "The answer [removed] stays as written.", text_of(events)
  end

  # ── Quotes ────────────────────────────────────────────────────────────────
  test "a quote is printed from the record, not from what the model wrote" do
    open_question = @entry.corpus_questions.find_by(cid: "c_d")
    quote = open_question.corpus_quotes.first
    assert_not_nil quote

    _result, events = run_chat([
      [ { name: "get_questions", input: { "ids" => [ open_question.id ] } } ],
      "One respondent said [[q:#{quote.id}]]."
    ])

    emitted = events.find { |e| e[:t] == "quote" }
    assert_not_nil emitted
    assert_equal quote.body, emitted[:body], "the body must come from the database, never the model"
  end

  test "a quote id that was never returned is dropped" do
    _result, events = run_chat([ fetch_step, "Someone said [[q:99999]]." ])

    assert_empty events.select { |e| e[:t] == "quote" }
    assert_not_includes text_of(events), "99999"
  end

  test "a quote belonging to a withdrawn Verto cannot be shown" do
    open_question = @entry.corpus_questions.find_by(cid: "c_d")
    quote = open_question.corpus_quotes.first
    @entry.withdraw!

    _result, events = run_chat([
      [ { name: "get_questions", input: { "ids" => [ open_question.id ] } } ],
      "Someone said [[q:#{quote.id}]]."
    ])

    assert_empty events.select { |e| e[:t] == "quote" }
  end

  # ── Honesty about an uncited answer ───────────────────────────────────────
  test "an answer full of figures and no citations is flagged" do
    _result, events = run_chat([
      fetch_step,
      "In my experience about 80% of young people are worried, and roughly 50% " \
      "want a green career, which is a well established pattern across many studies."
    ])

    warning = events.find { |e| e[:t] == "warning" }
    assert_not_nil warning, "tool_choice is auto — the model can answer without calling anything, and that must be visible"
  end

  test "a short answer with no figures is not flagged" do
    _result, events = run_chat([ fetch_step, "The corpus has nothing on that topic." ])

    assert_nil events.find { |e| e[:t] == "warning" }
  end

  # ── Dating the data ───────────────────────────────────────────────────────
  # The prompt requires the answer itself to say when the research was
  # collected. That rule is instructional, not structural, so the service logs
  # when it is missed — these pin the guard on both sides.
  test "a cited answer that names no fielded year is logged as drift" do
    logged = []
    stub_method(Rails.logger, :warn, ->(msg) { logged << msg }) do
      run_chat([ fetch_step, "75% are very worried [[c:1]]." ])
    end

    assert logged.any? { |msg| msg.include?("named no fielded year") },
      "an undated answer must be visible in the log, or the dating rule rots silently"
  end

  test "a cited answer that dates its research is not logged" do
    year = Time.current.year.to_s
    logged = []
    stub_method(Rails.logger, :warn, ->(msg) { logged << msg }) do
      run_chat([ fetch_step, "Research collected in #{year} found 75% very worried [[c:1]]." ])
    end

    assert_not logged.any? { |msg| msg.include?("named no fielded year") }
  end

  # ── Loop behaviour ────────────────────────────────────────────────────────
  test "sources are announced as they are fetched, before the answer streams" do
    _result, events = run_chat([ fetch_step, "Worry is high [[c:1]]." ])

    source_at = events.index { |e| e[:t] == "source" }
    token_at  = events.index { |e| e[:t] == "token" }
    assert_not_nil source_at
    assert_operator source_at, :<, token_at, "the rail should fill while the answer is still being written"
  end

  test "a source fetched twice is announced once, with no bookkeeping on the record" do
    result, events = run_chat([ fetch_step, fetch_step, "Worry is high [[c:1]]." ])

    sources = events.select { |e| e[:t] == "source" }
    assert_equal 1, sources.size, "the same question fetched twice is one source, announced once"
    assert_not sources.first[:source].key?("announced")
    assert_not result[:citations].first.key?("announced"),
      "the snapshot is the stored record of what was cited — bookkeeping must not ride into it"
  end

  test "the tool loop stops after MAX_TOOL_ROUNDS even if the model keeps calling" do
    chat = AskVertoChat.allocate
    endless = Array.new(20) { [ { name: "search_corpus", input: { "query" => "climate" } } ] }
    client = ScriptedClient.new(endless + [ "Done." ])
    chat.instance_variable_set(:@client, client)

    chat.call(messages: [ { role: "user", content: "hi" } ]) { |_| }

    creates = client.calls.count { |c| c[:op] == :create }
    assert_operator creates, :<=, AskVertoChat::MAX_TOOL_ROUNDS,
      "each round is a paid Claude call; the ceiling is the per-message cost bound"
  end

  test "the final stream call declares the tools the conversation's blocks reference" do
    chat = AskVertoChat.allocate
    client = ScriptedClient.new([ fetch_step, "Worry is high [[c:1]]." ])
    chat.instance_variable_set(:@client, client)

    chat.call(messages: [ { role: "user", content: "hi" } ]) { |_| }

    stream_call = client.calls.find { |c| c[:op] == :stream_raw }
    # The convo it sends carries tool_use/tool_result blocks, which the API
    # rejects unless the tools they reference are declared — and with tools
    # declared, only tool_choice "none" guarantees the answer is prose.
    assert_equal client.calls.first[:tools], stream_call[:tools]
    assert_equal({ type: "none" }, stream_call[:tool_choice])
  end

  test "every Claude call carries the per-request timeout the client-level setting cannot deliver" do
    chat = AskVertoChat.allocate
    client = ScriptedClient.new([ fetch_step, "Answer [[c:1]]." ])
    chat.instance_variable_set(:@client, client)

    chat.call(messages: [ { role: "user", content: "hi" } ]) { |_| }

    client.calls.each do |call|
      assert_equal AnthropicHelpers::ANTHROPIC_TIMEOUT_SECONDS,
                   call.dig(:request_options, :timeout),
                   "#{call[:op]} must carry request_options — the SDK overrides the client timeout"
    end
  end

  test "the corpus size is stated in the system prompt so the model knows its denominator" do
    chat = AskVertoChat.allocate
    client = ScriptedClient.new([ "No tools needed." ])
    chat.instance_variable_set(:@client, client)

    chat.call(messages: [ { role: "user", content: "hi" } ]) { |_| }

    scope_block = client.calls.first[:system].last[:text]
    assert_match(/1 Vertos/, scope_block)
    assert_match(/40 responses with answers/, scope_block)
  end
end
