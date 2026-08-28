require "test_helper"

# Capping how many answers a multi-select accepts.
#
# "Can we add the ability on select many answer types list and image to limit
#  the choices … the number must default to 'as many as there are answers' and
#  then the system needs to read how many options there are and dynamically
#  have options from 2 - N available, the number selected limits the
#  responders ability to check answers."
#
# The default is expressed as the ABSENCE of the key rather than as the option
# count, which is the only version of "as many as there are answers" that stays
# true after a sixth answer is added. Everything below follows from that.
class MaxChoicesTest < ActionDispatch::IntegrationTest
  def sign_in_org(suffix)
    user = User.create!(name: "U", email_address: "mc-#{suffix}-#{SecureRandom.hex(2)}@test.com",
                        password: "verylongpassword")
    org  = Organisation.create!(name: "O", slug: "mc-#{suffix}-#{SecureRandom.hex(2)}")
    org.memberships.create!(user: user, role: "admin")
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
    org
  end

  def blank_survey(org)
    org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                        default_locale: "en", locales: [ "en" ], cards: [])
  end

  def save_cards(survey, cards)
    patch survey_path(survey), params: { cards: cards }.to_json,
                               headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :success
    survey.reload.cards
  end

  # ── The sanitiser ─────────────────────────────────────────────────────────

  test "a cap inside 2…N-1 survives the round trip on both multi types" do
    org = sign_in_org("keep")
    s = blank_survey(org)

    cards = save_cards(s, [
      { "type" => "select_many", "cid" => "a", "text" => "Q",
        "options" => %w[a b c d], "max_choices" => 2 },
      { "type" => "select_many_grid", "cid" => "b", "text" => "Q",
        "options" => %w[a b c d], "max_choices" => 3 }
    ])
    assert_equal 2, cards.first["max_choices"]
    assert_equal 3, cards.second["max_choices"]
  end

  test "a cap at or above the option count is no cap at all, and is dropped" do
    org = sign_in_org("atcount")
    s = blank_survey(org)

    cards = save_cards(s, [
      { "type" => "select_many", "cid" => "a", "text" => "Q", "options" => %w[a b c], "max_choices" => 3 },
      { "type" => "select_many", "cid" => "b", "text" => "Q", "options" => %w[a b c], "max_choices" => 9 }
    ])
    assert_not cards.first.key?("max_choices"),
               "storing the option count would silently cap the card the moment a fourth option arrived"
    assert_not cards.second.key?("max_choices")
  end

  test "below two it is single-select wearing a checkbox, and is dropped" do
    org = sign_in_org("floor")
    s = blank_survey(org)

    [ 1, 0, -3, "abc" ].each do |bad|
      cards = save_cards(s, [ { "type" => "select_many", "cid" => "a", "text" => "Q",
                                "options" => %w[a b c d], "max_choices" => bad } ])
      assert_not cards.first.key?("max_choices"), "max_choices=#{bad.inspect} was kept"
    end
  end

  test "no other card type may carry one" do
    org = sign_in_org("types")
    s = blank_survey(org)

    cards = save_cards(s, [
      { "type" => "multiple_choice", "cid" => "a", "text" => "Q", "options" => %w[a b c d], "max_choices" => 2 },
      { "type" => "prioritise",      "cid" => "b", "text" => "Q", "options" => %w[a b c d], "max_choices" => 2 },
      { "type" => "select_one_grid", "cid" => "c", "text" => "Q", "options" => %w[a b c d], "max_choices" => 2 }
    ])
    cards.each do |c|
      assert_not c.key?("max_choices"),
                 "#{c['type']} takes one answer — a ceiling on it is dead data that would surprise " \
                 "whoever switches the card to a multi-select later"
    end
  end

  # THE re-clamp. The key is re-decided on every save rather than trusted,
  # which is what stops a cap outliving the options that justified it.
  test "deleting options past the cap drops it on the next save" do
    org = sign_in_org("shrink")
    s = blank_survey(org)

    save_cards(s, [ { "type" => "select_many", "cid" => "a", "text" => "Q",
                      "options" => %w[a b c d e], "max_choices" => 4 } ])
    assert_equal 4, s.reload.cards.first["max_choices"]

    cards = save_cards(s, [ { "type" => "select_many", "cid" => "a", "text" => "Q",
                              "options" => %w[a b c], "max_choices" => 4 } ])
    assert_not cards.first.key?("max_choices"),
               "a card down to three answers cannot honour a ceiling of four"
  end

  # ── The server-side bound ─────────────────────────────────────────────────
  # The player refuses the extra tap, but /progress is public and takes JSON.
  # Array answers had no length bound of any kind before this — clamp_free_text
  # only ever touched Strings.

  def live_survey(org, cards)
    org.surveys.create!(
      title: "T", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ], cards: cards,
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current
    )
  end

  def capped_deck(max: 2)
    [ { "type" => "select_many", "cid" => "q", "text" => "Pick some",
        "options" => %w[a b c d e], "max_choices" => max } ]
  end

  test "an over-long selection posted straight at progress is truncated" do
    org = sign_in_org("clamp")
    s = live_survey(org, capped_deck)

    post progress_survey_path(s.publish_token),
         params: { session_token: "mc-1",
                   answers: { "0" => { "type" => "select_many", "value" => %w[a b c d e] } } },
         as: :json
    assert_response :success

    stored = s.responses.find_by(session_token: "mc-1").answers.dig("0", "value")
    assert_equal %w[a b], stored,
                 "the leading two, in the order they arrived — which is the DOM order the player reads"
  end

  test "an uncapped card still takes every answer" do
    org = sign_in_org("uncapped")
    s = live_survey(org, [ capped_deck.first.except("max_choices") ])

    post progress_survey_path(s.publish_token),
         params: { session_token: "mc-2",
                   answers: { "0" => { "type" => "select_many", "value" => %w[a b c d e] } } },
         as: :json
    assert_equal %w[a b c d e], s.responses.find_by(session_token: "mc-2").answers.dig("0", "value")
  end

  # The cap is re-derived from the deck as it stands NOW, so editing the card
  # after a cap was set cannot leave a stale ceiling trimming live answers.
  test "the ceiling is read off the deck, not off the stored key alone" do
    org = sign_in_org("live")
    s = live_survey(org, capped_deck)
    assert_equal 2, s.max_choices_at("0")

    s.update_columns(cards: [ s.cards.first.merge("options" => %w[a b]) ])
    assert_nil s.reload.max_choices_at("0"),
               "two options and a ceiling of two is not a ceiling"

    assert_nil s.max_choices_at("9"), "a card that isn't there caps nothing"
  end

  test "a scalar answer and a non-multi card are passed through untouched" do
    org = sign_in_org("passthru")
    s = live_survey(org, capped_deck)

    answers = { "0" => { "type" => "select_many", "value" => "a" },
                "1" => { "type" => "multiple_choice", "value" => %w[x y z] } }
    assert_equal answers, s.clamp_selection_count(answers)
  end
end
