require "test_helper"

# Replaying a stored answer.
#
# The live stream resolves markers as they arrive; this is the other half — a
# reloaded conversation has to read exactly as it did when it was written, with
# the same citations resolving to the same rows. And a quote whose Verto has
# since been withdrawn must stop appearing in the OLD answer too, which is the
# part that is easy to forget: the creator was promised withdrawal stops future
# use, and a page that keeps printing their respondents' words is not that.
class AskHelperTest < ActionView::TestCase
  include AskHelper

  def setup
    @org = Organisation.create!(name: "Anglo American Foundation", slug: "ah-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "U", email_address: "ah-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @survey = @org.surveys.create!(title: "Valparaíso Youth Pulse", theme: "Climate", audience_age: "all",
                                   key_insight: "x", default_locale: "en", locales: [ "en" ], cards: [])
    @entry = CorpusEntry.create!(survey: @survey, organisation: @org,
                                 review_status: "approved", opted_in_at: 1.day.ago)
    @question = @entry.corpus_questions.create!(
      cid: "c_w", position: 0, card_type: "multiple_choice",
      question_text: "How worried are you about climate change?",
      response_count: 2648, distribution: { "Very worried" => 864 }
    )
    @quote = @question.corpus_quotes.create!(
      body: "Que la gente deje de pensar que no sirve de nada lo que hace una sola persona.",
      theme: "collective agency"
    )
  end

  # Named `answer` rather than `message`: ActionView::TestCase inherits
  # Minitest's own #message, and overriding it here breaks assertion reporting
  # in ways that surface as a confusing NOT NULL violation.
  def answer(body, citations: [])
    thread = AskThread.create!(organisation: @org, user: @user)
    thread.ask_messages.create!(role: "assistant", text: body, citations: citations)
  end

  def citation(n = 1)
    { "n" => n, "corpus_question_id" => @question.id, "question" => @question.question_text,
      "verto" => "Valparaíso Youth Pulse", "organisation" => "Anglo American Foundation",
      "responses" => 2648 }
  end

  test "a citation marker becomes a clickable chip carrying its source" do
    html = render_ask_answer(answer("Worry is high [[c:1]].", citations: [ citation ]))

    assert_includes html, "ask-cite"
    assert_includes html, "Valparaíso Youth Pulse · How worried are you about climate change?"
    assert_includes html, "Worry is high"
    assert_not_includes html, "[[c:1]]"
  end

  test "a marker with no stored source leaves nothing behind" do
    html = render_ask_answer(answer("Worry is high [[c:9]].", citations: []))

    assert_not_includes html, "ask-cite"
    assert_not_includes html, "[[c:9]]"
    assert_includes html, "Worry is high"
  end

  test "a quote is printed from the record" do
    html = render_ask_answer(answer("One said [[q:#{@quote.id}]].", citations: [ citation ]))

    assert_includes html, "Que la gente deje de pensar"
    assert_includes html, "collective agency"
    assert_includes html, "ask-quote"
  end

  test "a withdrawn Verto's quote stops appearing in an answer already given" do
    stored = answer("One said [[q:#{@quote.id}]].", citations: [ citation ])
    @entry.withdraw!

    html = render_ask_answer(stored)

    assert_not_includes html, "Que la gente deje de pensar",
      "withdrawal must stop the words being shown, not only stop new answers using them"
  end

  test "answer text is escaped, not trusted" do
    html = render_ask_answer(answer("<script>alert(1)</script> [[c:1]]", citations: [ citation ]))

    assert_not_includes html, "<script>"
    assert_includes html, "&lt;script&gt;"
  end

  test "an answer with no markers renders unchanged" do
    html = render_ask_answer(answer("The corpus has nothing on that topic."))

    assert_includes html, "The corpus has nothing on that topic."
  end

  test "stale_sources names a citation whose Verto has left the corpus" do
    stored = answer("Worry is high [[c:1]].", citations: [ citation ])
    assert_empty stored.stale_sources

    @entry.withdraw!

    assert_equal 1, stored.stale_sources.size,
      "a reader about to quote a figure deserves to know its source has been pulled"
  end
end
