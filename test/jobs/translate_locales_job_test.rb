require "test_helper"

# The job that fills in a language's i18n entries after the Verto exists.
#
# Every test here is about DURABILITY rather than translation quality: what
# survives when one language fails, when the deck moves underneath, when the
# process dies mid-run, and whether a half-finished language can ever be
# repaired. Those are the ways a creator ends up staring at "Translating…"
# for ever, which is what this job was rewritten to stop.
class TranslateLocalesJobTest < ActiveSupport::TestCase
  def setup
    @org = Organisation.create!(name: "T", slug: "t-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(
      title: "T", theme: "T", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: %w[en es fr de],
      cards: [
        { "type" => "multiple_choice", "cid" => "c1", "text" => "Colour?", "options" => %w[Blue Green] },
        { "type" => "open_ended", "cid" => "c2", "text" => "Why?" }
      ]
    )
  end

  # Stand in for Claude: returns a plausible translation for every card it is
  # handed, or raises for locales named in `failing`.
  # stub_method treats a callable value as the REPLACEMENT IMPLEMENTATION, so a
  # translator double (which answers #call) has to be handed back from a lambda
  # rather than passed directly — otherwise SurveyTranslator.new invokes the
  # double instead of returning it.
  def translator_double(failing: [])
    fake = Object.new
    fake.define_singleton_method(:call) do |cards:, target_locale:, source_locale:|
      raise "boom" if failing.include?(target_locale.to_s)
      Array(cards).map do |c|
        { "text" => "#{target_locale}:#{c['text']}",
          "options" => Array(c["options"]).map { |o| "#{target_locale}:#{o}" } }
      end
    end
    fake
  end

  def with_translator(failing: [], &block)
    fake = translator_double(failing: failing)
    stub_method(SurveyTranslator, :new, ->(*_a, **_k) { fake }, &block)
  end

  def entry(cid, locale)
    @survey.reload.cards.find { |c| c["cid"] == cid }&.dig("i18n", locale)
  end

  test "each language is written as soon as it is done, not at the end of the run" do
    # The heart of the fix. One job per locale, each persisting on its own.
    with_translator do
      perform_enqueued_jobs { TranslateLocalesJob.enqueue_for(@survey, %w[es fr de]) }
    end

    %w[es fr de].each do |loc|
      assert_equal "#{loc}:Colour?", entry("c1", loc)["text"], "#{loc} should have landed"
      assert_equal "done", SurveyTranslation.find_by(survey: @survey, locale: loc).status
    end
  end

  test "one language failing does not cost the languages that succeeded" do
    # The old job wrote once at the end, so anything that killed the run threw
    # away every language in it. This is the regression guard for that.
    with_translator(failing: [ "fr" ]) do
      perform_enqueued_jobs(except: ->(_) { false }) do
        TranslateLocalesJob.enqueue_for(@survey, %w[es fr de])
      end
    rescue StandardError
      # The French job exhausts its retries and re-raises; the others are
      # separate jobs and are unaffected.
    end

    assert_equal "es:Colour?", entry("c1", "es")["text"], "Spanish must survive a French failure"
    assert_equal "de:Colour?", entry("c1", "de")["text"], "German must survive a French failure"
    assert_nil entry("c1", "fr")
  end

  test "a failed language is recorded as failed, not left looking like it is still coming" do
    with_translator(failing: [ "fr" ]) do
      perform_enqueued_jobs { TranslateLocalesJob.enqueue_for(@survey, [ "fr" ]) } rescue StandardError
    end

    row = SurveyTranslation.find_by(survey: @survey, locale: "fr")
    assert_equal "failed", row.status,
                 "a creator is owed an answer, not an indefinite 'Translating…'"
    assert row.last_error.present?
  end

  test "a half-finished language is repaired by running it again" do
    # The old skip was all-or-nothing per locale: once every card had SOME
    # entry the language was skipped for ever, so a partial run could never be
    # completed. Now the job asks only for the cards that are missing one.
    cards = @survey.cards
    cards[0] = cards[0].merge("i18n" => { "es" => { "text" => "ya traducido", "options" => %w[Azul Verde] } })
    @survey.update!(cards: cards)

    with_translator do
      perform_enqueued_jobs { TranslateLocalesJob.enqueue_for(@survey, [ "es" ]) }
    end

    assert_equal "ya traducido", entry("c1", "es")["text"], "an existing translation is left alone"
    assert_equal "es:Why?", entry("c2", "es")["text"], "the missing card is filled in"
  end

  test "a language already complete costs nothing and is marked done" do
    with_translator do
      perform_enqueued_jobs { TranslateLocalesJob.enqueue_for(@survey, [ "es" ]) }
    end
    before = @survey.reload.cards

    calls = 0
    counting = Object.new
    counting.define_singleton_method(:call) { |**| calls += 1; [] }
    stub_method(SurveyTranslator, :new, ->(*_a, **_k) { counting }) do
      perform_enqueued_jobs { TranslateLocalesJob.enqueue_for(@survey, [ "es" ]) }
    end

    assert_equal 0, calls, "re-translating a finished language would overwrite hand-edited wording"
    assert_equal before, @survey.reload.cards
    assert_equal "done", SurveyTranslation.find_by(survey: @survey, locale: "es").status
  end

  test "a deck that moved mid-translation loses only the language in flight" do
    # The guard still refuses to overwrite a concurrent save — that is the
    # point of it — but the blast radius is now one language, and its row says
    # what happened so it can be retried.
    with_translator do
      perform_enqueued_jobs { TranslateLocalesJob.enqueue_for(@survey, [ "es" ]) }
    end
    assert_equal "done", SurveyTranslation.find_by(survey: @survey, locale: "es").status

    moving = Object.new
    survey = @survey
    moving.define_singleton_method(:call) do |cards:, target_locale:, source_locale:|
      # Somebody saves the deck while Claude is working.
      survey.class.find(survey.id).update!(cards: survey.reload.cards + [
        { "type" => "open_ended", "cid" => "c3", "text" => "Late addition" }
      ])
      Array(cards).map { |c| { "text" => "fr:#{c['text']}", "options" => [] } }
    end

    stub_method(SurveyTranslator, :new, ->(*_a, **_k) { moving }) do
      perform_enqueued_jobs { TranslateLocalesJob.enqueue_for(@survey, [ "fr" ]) } rescue StandardError
    end

    assert_equal "es:Colour?", entry("c1", "es")["text"], "the finished language is untouched"
    assert_equal "Late addition", @survey.reload.cards.last["text"], "the concurrent save survives"
  end

  test "a deck that moves during a six-language run does not throw away the finished ones" do
    # THE regression this rewrite exists for. The old job took every locale in
    # one unit of work and wrote the deck once at the end, against a digest
    # taken before the first Claude call. Ticking several languages from the
    # rail made that window minutes long, so a single autosave anywhere in it
    # discarded every language in the run — including the ones that had already
    # come back. Now each language is its own job and persists on its own, so
    # the save costs at most the one in flight.
    survey = @survey
    seen = []
    shifty = Object.new
    shifty.define_singleton_method(:call) do |cards:, target_locale:, source_locale:|
      seen << target_locale.to_s
      if seen.size == 2
        # Somebody saves the deck while the SECOND language is being translated.
        Survey.find(survey.id).update!(cards: Survey.find(survey.id).cards + [
          { "type" => "open_ended", "cid" => "c_late", "text" => "Late addition" }
        ])
      end
      Array(cards).map { |c| { "text" => "#{target_locale}:#{c['text']}", "options" => [] } }
    end

    stub_method(SurveyTranslator, :new, ->(*_a, **_k) { shifty }) do
      perform_enqueued_jobs { TranslateLocalesJob.enqueue_for(@survey, %w[es fr de]) }
    rescue StandardError
      nil
    end

    assert_equal "es:Colour?", entry("c1", "es")&.dig("text"),
                 "the language that finished BEFORE the save must survive it"
    assert_equal "Late addition", @survey.reload.cards.last["text"],
                 "and the concurrent save itself is never overwritten"
  end

  test "a locale the Verto does not carry is ignored" do
    with_translator do
      perform_enqueued_jobs { TranslateLocalesJob.enqueue_for(@survey, [ "ja" ]) }
    end
    assert_nil entry("c1", "ja")
  end

  test "asking again after a failure starts a fresh run rather than one already spent" do
    row = SurveyTranslation.create!(survey: @survey, locale: "fr", status: "failed",
                                     attempts: SurveyTranslation::MAX_ATTEMPTS,
                                     last_error: "boom")
    SurveyTranslation.enqueue!(@survey, "fr")
    row.reload
    assert_equal "queued", row.status
    assert_equal 0, row.attempts
    assert_nil row.last_error
  end
end
