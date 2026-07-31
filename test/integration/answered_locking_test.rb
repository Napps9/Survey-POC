require "test_helper"

# BUG-024, server side. `answered?` decides what `locked_merge` protects from a
# later submit — so it decides whether a respondent can re-score a card they
# have already committed to.
#
# The behavioural parity with the client's `_isAnswered` is asserted in
# test/system/answer_parity_test.rb; this covers what the rule actually does to
# stored data.
class AnsweredLockingTest < ActionDispatch::IntegrationTest
  CARDS = [
    { "type" => "welcome_card", "title" => "Hi" },
    { "type" => "multiple_choice", "cid" => "q1", "text" => "Pick one",
      "options" => %w[A B], "allow_other" => true, "tokens" => { "A" => { "t1" => 5 } } },
    # Token-awarding on purpose: locked_merge only protects graded or awarding
    # cards, so a plain grid here would have made the empty-grid test below pass
    # whether or not the rule was right.
    { "type" => "select_one_grid", "cid" => "q2", "text" => "Rate these",
      "options" => %w[Agree Disagree], "rows" => %w[Food Staff],
      "tokens" => { "Agree" => { "t1" => 3 } } }
  ].freeze

  def setup
    @org = Organisation.create!(name: "O", slug: "al-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(
      title: "Lock", theme: "T", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ], cards: CARDS,
      tokenisation_enabled: true, token_types: [ { "id" => "t1", "name" => "Tokens", "icon" => "★" } ],
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current
    )
    @token = SecureRandom.uuid
  end

  def submit(answers)
    post submit_survey_path(@survey.publish_token),
         params: { session_token: @token, answers: answers }.to_json,
         headers: { "CONTENT_TYPE" => "application/json" }
  end

  def stored
    @survey.reload.responses.find_by(session_token: @token)
  end

  test "an answered card is protected from a later overwrite" do
    submit("1" => { "type" => "multiple_choice", "value" => "A" })
    submit("1" => { "type" => "multiple_choice", "value" => "B" })

    assert_equal "A", stored.answers.dig("1", "value"),
                 "a token-awarding card must not be re-scorable once answered"
  end

  # The "Other"-only case. It IS an answer, so it locks — which is precisely why
  # the client has to lock it too, instead of leaving the respondent believing
  # they can still change it.
  test "an Other-only answer counts as answered and locks" do
    submit("1" => { "type" => "multiple_choice", "value" => nil, "other" => "Cheese" })
    submit("1" => { "type" => "multiple_choice", "value" => "A" })

    assert_equal "Cheese", stored.answers.dig("1", "other")
    assert_nil stored.answers.dig("1", "value")
  end

  # The case the server had wrong: an empty grid is not an answer, so a
  # respondent who skipped it can come back and answer it properly.
  test "an empty grid answer does not lock the card" do
    submit("2" => { "type" => "select_one_grid", "value" => {} })
    submit("2" => { "type" => "select_one_grid", "value" => { "Food" => "Agree" } })

    assert_equal({ "Food" => "Agree" }, stored.answers.dig("2", "value"),
                 "a grid with nothing picked was never an answer — locking it cost the " \
                 "respondent the card they meant to come back to")
  end

  test "a skipped card is still answerable later" do
    submit("1" => { "type" => "multiple_choice", "value" => nil })
    submit("1" => { "type" => "multiple_choice", "value" => "A" })

    assert_equal "A", stored.answers.dig("1", "value")
  end

  test "a blank Other does not lock the card either" do
    submit("1" => { "type" => "multiple_choice", "value" => nil, "other" => "   " })
    submit("1" => { "type" => "multiple_choice", "value" => "A" })

    assert_equal "A", stored.answers.dig("1", "value")
  end

  # ── The `answered` column (BUG-025) ──────────────────────────────────────
  #
  # content_answered? drives the `answered` flag, which every responder-scoped
  # view filters on. It checked only `value.present?`, so a respondent whose one
  # answer was typed into the Other box was recorded as not having answered and
  # vanished from the creator's counts — a real, completed response, uncounted.

  test "a response answered only via Other counts as answered" do
    submit("1" => { "type" => "multiple_choice", "value" => nil, "other" => "Cheese" })

    assert stored.answered?,
           "an Other write-in is an answer; recording it as unanswered drops a real " \
           "respondent out of every responder-scoped view"
  end

  test "an empty response is still not answered" do
    # The negative case: without it, `answered` could be set unconditionally and
    # every abandoned session would be counted as a respondent.
    submit("1" => { "type" => "multiple_choice", "value" => nil })

    refute stored.answered?
  end

  test "a whitespace-only Other does not count" do
    submit("1" => { "type" => "multiple_choice", "value" => nil, "other" => "   " })

    refute stored.answered?
  end

  test "the model and the controller share one definition" do
    # Three implementations of this rule existed and all three disagreed. The
    # controller now delegates, so this asserts they cannot drift again.
    [ nil, {}, { "value" => nil }, { "value" => "A" },
      { "value" => nil, "other" => "x" }, { "value" => {} }, { "value" => [ 1 ] } ].each do |entry|
      assert_equal Response.answered_entry?(entry),
                   PlayerController.new.send(:answered?, entry),
                   "the controller and the model disagree about #{entry.inspect}"
    end
  end
end
