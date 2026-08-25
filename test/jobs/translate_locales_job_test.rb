require "test_helper"

# TranslateLocalesJob — the after-the-fact translation pass for languages added
# in the editor's Language block. Its contract: touch ONLY the locales it was
# handed, and within them only cards with no entry yet, so hand-edited or
# previously stored translations are never re-billed or overwritten.
class TranslateLocalesJobTest < ActiveJob::TestCase
  def with_fake_translator
    fake = Object.new
    fake.define_singleton_method(:call) do |cards:, target_locale:, source_locale:|
      Array(cards).map { |c| { "text" => "#{target_locale}:#{c['text']}", "options" => Array(c["options"]) } }
    end
    SurveyTranslator.define_singleton_method(:new) { |*| fake }
    yield
  ensure
    SurveyTranslator.singleton_class.remove_method(:new)
  end

  def survey(cards:, locales:)
    org = Organisation.create!(name: "O", slug: "tlj-#{SecureRandom.hex(3)}")
    org.surveys.create!(
      title: "T", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: locales, cards: cards
    )
  end

  test "fills entries for the named locale and leaves existing entries alone" do
    s = survey(
      cards: [
        { "type" => "yes_no", "text" => "Fresh", "options" => [ "Yes", "No" ] },
        { "type" => "yes_no", "text" => "Kept", "options" => [ "Yes", "No" ],
          "i18n" => { "fr" => { "text" => "Gardé", "options" => [ "Oui", "Non" ] } } }
      ],
      locales: %w[en fr]
    )

    with_fake_translator { TranslateLocalesJob.perform_now(s.id, [ "fr" ]) }

    s.reload
    assert_equal "fr:Fresh", s.cards[0].dig("i18n", "fr", "text")
    assert_equal "Gardé", s.cards[1].dig("i18n", "fr", "text"),
                 "a card that already carried the language must keep its entry"
  end

  test "ignores locales that aren't among the survey's secondaries" do
    s = survey(cards: [ { "type" => "yes_no", "text" => "Q", "options" => [ "Yes", "No" ] } ], locales: %w[en])

    with_fake_translator { TranslateLocalesJob.perform_now(s.id, [ "fr" ]) }
    assert_nil s.reload.cards.first["i18n"]
  end

  test "a fully translated locale is not re-billed" do
    s = survey(
      cards: [ { "type" => "yes_no", "text" => "Q", "options" => [ "Yes", "No" ],
                 "i18n" => { "fr" => { "text" => "Qf", "options" => [ "Oui", "Non" ] } } } ],
      locales: %w[en fr]
    )

    called = false
    fake = Object.new
    fake.define_singleton_method(:call) { |**| called = true; [] }
    SurveyTranslator.define_singleton_method(:new) { |*| fake }
    begin
      TranslateLocalesJob.perform_now(s.id, [ "fr" ])
    ensure
      SurveyTranslator.singleton_class.remove_method(:new)
    end

    assert_not called, "every card already carries fr — nothing to translate"
    assert_equal "Qf", s.reload.cards.first.dig("i18n", "fr", "text")
  end
end
