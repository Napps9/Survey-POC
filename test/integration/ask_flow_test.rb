require "test_helper"

# The Ask Verto conversation, walked through the real HTTP surface.
#
# AskVertoChatTest proves the answer loop; AskVertoConsentTest proves the gate.
# This proves the plumbing between them — the routes, the NDJSON stream, what is
# persisted and for whom. It exists because the route once declared `:id` while
# the controller read `params[:thread_id]`, and every question 404ed with all
# 1,700 other tests green: nothing POSTed a question over HTTP until this file.
class AskFlowTest < ActionDispatch::IntegrationTest
  PASSWORD = "verylongpassword".freeze

  # Stands in for AskVertoChat: replays a scripted event stream and returns the
  # persistence payload, so these tests exercise the HTTP plumbing without a
  # Claude client. `calls` records invocations so a test can assert the service
  # was never reached at all.
  class FakeChat
    attr_reader :calls

    def initialize(events: [], result: { text: "", citations: [] }, raises: nil)
      @events = events
      @result = result
      @raises = raises
      @calls  = []
    end

    def call(messages:, scope: {}, &emit)
      @calls << { messages: messages, scope: scope }
      raise @raises if @raises

      @events.each { |event| emit&.call(event) }
      @result
    end
  end

  def setup
    @user = User.create!(name: "Asker", email_address: "af-#{SecureRandom.hex(3)}@test.com",
                         password: PASSWORD)
    @org  = Organisation.create!(name: "Fundación Piensa", slug: "af-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")

    @survey = @org.surveys.create!(
      title: "Valparaíso Youth Pulse", theme: "Climate Action", audience_age: "all",
      key_insight: "x", default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "multiple_choice", "cid" => "c_w",
                 "text" => "How worried are you about climate change?",
                 "options" => [ "Very worried", "Not worried" ] } ]
    )
    40.times do |i|
      @survey.responses.create!(session_token: SecureRandom.hex(8), status: "completed",
                                answers: { "0" => { "value" => i < 30 ? "Very worried" : "Not worried" } })
    end
    # Offered, approved and indexed — the message tests need a citable corpus.
    CorpusEnrolment.new(@survey, user: @user, reviewer: "reviewer@vertonow.com").call
  end

  def sign_in(user = @user)
    post session_path, params: { email_address: user.email_address, password: PASSWORD }
    follow_redirect! if response.redirect?
  end

  def thread(org: @org, user: @user)
    org.ask_threads.create!(user: user)
  end

  def citation
    question = CorpusQuestion.first
    { "n" => 1, "corpus_question_id" => question.id, "question" => question.question_text }
  end

  def events_of(body)
    body.split("\n").reject(&:blank?).map { |line| JSON.parse(line) }
  end

  # ── Threads ───────────────────────────────────────────────────────────────
  test "creating a thread scopes it to the organisation and lands on it" do
    sign_in

    assert_difference -> { @org.ask_threads.count } => 1 do
      post ask_threads_path
    end
    created = @org.ask_threads.recent.first
    assert_redirected_to ask_path(thread_id: created.id)
    assert_equal @user, created.user
  end

  test "deleting a thread removes it and its messages" do
    sign_in
    mine = thread
    mine.ask_messages.create!(role: "user", text: "Hello?")

    delete ask_thread_path(mine)

    assert_response :redirect
    assert_nil AskThread.find_by(id: mine.id)
    assert_equal 0, AskMessage.where(ask_thread_id: mine.id).count
  end

  test "another organisation's thread cannot be deleted" do
    other_org = Organisation.create!(name: "Other", slug: "afo-#{SecureRandom.hex(3)}")
    theirs = other_org.ask_threads.create!(user: @user)
    sign_in

    delete ask_thread_path(theirs)

    assert_response :not_found
    assert AskThread.exists?(theirs.id)
  end

  # ── Messages ──────────────────────────────────────────────────────────────
  test "a question streams NDJSON events and persists both turns" do
    sign_in
    mine = thread
    mine.update_column(:updated_at, 1.day.ago)

    fake = FakeChat.new(
      events: [
        { t: "status", text: "Searching the corpus…" },
        { t: "source", source: citation },
        { t: "token",  text: "Most respondents are worried " },
        { t: "cite",   n: 1 },
        { t: "done",   citations: [ citation ] }
      ],
      result: { text: "Most respondents are worried [[c:1]]", citations: [ citation ] }
    )

    stub_method(AskVertoChat, :new, ->(*) { fake }) do
      post ask_thread_messages_path(mine),
           params: { message: "How worried are people?" }.to_json,
           headers: { "Content-Type" => "application/json" }
    end

    assert_response :success
    assert_match %r{application/x-ndjson}, response.content_type
    types = events_of(response.body).map { |e| e["t"] }
    assert_equal %w[status source token cite done], types

    assert_equal 1, fake.calls.size
    assert_equal({ role: "user", content: "How worried are people?" }, fake.calls.first[:messages].last)

    turns = mine.ask_messages.reload.to_a
    assert_equal %w[user assistant], turns.map(&:role)
    assert_equal "How worried are people?", turns.first.text
    assert_equal "Most respondents are worried [[c:1]]", turns.last.text
    assert_equal [ citation ], turns.last.citation_list
    assert_operator mine.reload.updated_at, :>, 1.hour.ago, "answering should float the thread up the rail"
  end

  test "a blank question is a 400 and persists nothing" do
    sign_in
    mine = thread

    fake = FakeChat.new
    stub_method(AskVertoChat, :new, ->(*) { fake }) do
      post ask_thread_messages_path(mine),
           params: { message: "   " }.to_json,
           headers: { "Content-Type" => "application/json" }
    end

    assert_response :bad_request
    assert_equal 0, mine.ask_messages.count
    assert_empty fake.calls
  end

  test "another organisation's thread is a 404 and the service is never invoked" do
    other_org = Organisation.create!(name: "Other", slug: "afo-#{SecureRandom.hex(3)}")
    theirs = other_org.ask_threads.create!(user: @user)
    sign_in

    fake = FakeChat.new
    stub_method(AskVertoChat, :new, ->(*) { fake }) do
      post ask_thread_messages_path(theirs),
           params: { message: "What did they collect?" }.to_json,
           headers: { "Content-Type" => "application/json" }
    end

    assert_response :not_found
    assert_equal 0, theirs.ask_messages.count
    assert_empty fake.calls
  end

  test "a signed-out visitor is redirected, not served" do
    post ask_threads_path
    assert_response :redirect

    post ask_thread_messages_path(thread),
         params: { message: "Anyone there?" }.to_json,
         headers: { "Content-Type" => "application/json" }
    assert_response :redirect
    assert_equal 0, AskMessage.count
  end

  test "a service failure surfaces as an error event, not a 500" do
    sign_in
    mine = thread

    fake = FakeChat.new(raises: RuntimeError.new("boom"))
    stub_method(AskVertoChat, :new, ->(*) { fake }) do
      post ask_thread_messages_path(mine),
           params: { message: "How worried are people?" }.to_json,
           headers: { "Content-Type" => "application/json" }
    end

    error = events_of(response.body).find { |e| e["t"] == "error" }
    assert_equal I18n.t("ask.chat.error"), error["text"]
    # The question is kept; only the answer is missing.
    assert_equal [ "user" ], mine.ask_messages.reload.map(&:role)
  end
end
