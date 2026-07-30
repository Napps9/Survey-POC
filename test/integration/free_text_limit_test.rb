require "test_helper"

# The free-text answer cap. It was a hardcoded 200 in the card partial and
# advisory only — no maxlength on the textarea and no server check anywhere, so
# the counter turned pink and the answer saved in full regardless. It's now
# per-card and actually enforced, on the server, where it counts.
class FreeTextLimitTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(name: "U", email_address: "ftl-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "ftl-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")
  end

  def sign_in!
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def survey_with(cards, published: true)
    attrs = { title: "T", theme: "T", audience_age: "all", key_insight: "x",
              default_locale: "en", locales: [ "en" ], cards: cards }
    attrs.merge!(publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current) if published
    @org.surveys.create!(**attrs)
  end

  def answer!(survey, answers)
    post progress_survey_path(survey.publish_token),
         params: { session_token: SecureRandom.uuid, answers: answers }.to_json,
         headers: { "CONTENT_TYPE" => "application/json" }
    survey.responses.order(created_at: :desc).first
  end

  # ── The limit itself ──────────────────────────────────────────────────────

  test "the default applies when a card sets nothing" do
    s = survey_with([ { "type" => "open_ended", "text" => "Why?" } ])
    assert_equal Survey::DEFAULT_FREE_TEXT_LIMIT, s.free_text_limit_at(0)
  end

  test "a per-card limit wins, and is clamped into range" do
    s = survey_with([ { "type" => "open_ended", "text" => "Why?", "char_limit" => 500 } ])
    assert_equal 500, s.free_text_limit_at(0)

    s.update!(cards: [ { "type" => "open_ended", "text" => "Why?", "char_limit" => 99_999 } ])
    assert_equal Survey::FREE_TEXT_LIMIT_RANGE.max, s.reload.free_text_limit_at(0)

    s.update!(cards: [ { "type" => "open_ended", "text" => "Why?", "char_limit" => 2 } ])
    assert_equal Survey::FREE_TEXT_LIMIT_RANGE.min, s.reload.free_text_limit_at(0)
  end

  test "an index off the end of the deck falls back to the default" do
    s = survey_with([ { "type" => "open_ended", "text" => "Why?" } ])
    assert_equal Survey::DEFAULT_FREE_TEXT_LIMIT, s.free_text_limit_at(99)
  end

  test "the sanitiser clamps the stored value and drops a default-valued one" do
    kept = Survey.sanitize_cards_images!([ { "type" => "open_ended", "text" => "Q", "char_limit" => 9_999 } ])
    assert_equal Survey::FREE_TEXT_LIMIT_RANGE.max, kept.first["char_limit"]

    default = Survey.sanitize_cards_images!([
      { "type" => "open_ended", "text" => "Q", "char_limit" => Survey::DEFAULT_FREE_TEXT_LIMIT }
    ])
    assert_not default.first.key?("char_limit"), "a deck nobody changed carries no key"
  end

  # ── Server enforcement — the part that was missing entirely ────────────────

  test "an over-length answer is truncated on the way in" do
    s = survey_with([ { "type" => "open_ended", "text" => "Why?", "char_limit" => 80 } ])
    resp = answer!(s, { "0" => { "value" => "x" * 500 } })
    assert_equal 80, resp.answers["0"]["value"].length
  end

  test "the maxlength cannot be bypassed by posting JSON directly" do
    s = survey_with([ { "type" => "open_ended", "text" => "Why?" } ])
    resp = answer!(s, { "0" => { "value" => "y" * 5_000 } })
    assert_equal Survey::DEFAULT_FREE_TEXT_LIMIT, resp.answers["0"]["value"].length,
                 "a public JSON endpoint can't rely on the browser to bound this"
  end

  test "the Other box is bounded too" do
    s = survey_with([ { "type" => "multiple_choice", "text" => "Pick", "options" => %w[A B],
                        "allow_other" => true, "char_limit" => 40 } ])
    resp = answer!(s, { "0" => { "value" => nil, "other" => "z" * 300 } })
    assert_equal 40, resp.answers["0"]["other"].length
  end

  test "an answer inside the limit is stored untouched" do
    s = survey_with([ { "type" => "open_ended", "text" => "Why?" } ])
    resp = answer!(s, { "0" => { "value" => "A short, complete answer." } })
    assert_equal "A short, complete answer.", resp.answers["0"]["value"]
  end

  test "non-text answers pass through unharmed" do
    s = survey_with([ { "type" => "select_many", "text" => "Pick", "options" => %w[A B C] },
                      { "type" => "rating", "text" => "Score" } ])
    resp = answer!(s, { "0" => { "value" => %w[A B C] }, "1" => { "value" => 4 } })
    assert_equal %w[A B C], resp.answers["0"]["value"]
    assert_equal 4, resp.answers["1"]["value"]
  end

  test "each card is clamped to its own limit, not the first one's" do
    s = survey_with([ { "type" => "open_ended", "text" => "Short", "char_limit" => 20 },
                      { "type" => "open_ended", "text" => "Long",  "char_limit" => 1000 } ])
    resp = answer!(s, { "0" => { "value" => "a" * 100 }, "1" => { "value" => "b" * 100 } })
    assert_equal 20, resp.answers["0"]["value"].length
    assert_equal 100, resp.answers["1"]["value"].length, "well inside its own limit"
  end

  test "clamping survives the quiz/token locked merge" do
    s = survey_with([ { "type" => "open_ended", "text" => "Why?", "char_limit" => 30,
                        "token_award" => { "t1" => 3 } } ])
    s.update!(tokenisation_enabled: true, token_types: [ { "id" => "t1", "icon" => "★", "name" => "Stars" } ])
    resp = answer!(s, { "0" => { "value" => "q" * 400 } })
    assert_equal 30, resp.answers["0"]["value"].length
  end

  # ── What the respondent and creator see ───────────────────────────────────

  test "the player renders a real maxlength, not just a counter" do
    s = survey_with([ { "type" => "open_ended", "text" => "Why?", "char_limit" => 140 } ])
    get play_survey_path(s.publish_token)
    assert_response :success
    assert_select "textarea.freeform-textarea[maxlength='140']"
    assert_select "[data-freeform-max-value='140']"
  end

  test "the editor offers the length control, set to the card's value" do
    sign_in!
    s = survey_with([ { "type" => "open_ended", "text" => "Why?", "char_limit" => 500 } ], published: false)
    get survey_path(s)
    assert_response :success
    assert_select "select[data-char-limit] option[value='500'][selected]"
  end

  test "a limit outside the presets stays selectable rather than being rewritten" do
    sign_in!
    s = survey_with([ { "type" => "open_ended", "text" => "Why?", "char_limit" => 333 } ], published: false)
    get survey_path(s)
    assert_select "select[data-char-limit] option[value='333'][selected]"
  end

  test "the autosave stores a changed limit" do
    sign_in!
    s = survey_with([ { "type" => "open_ended", "text" => "Why?" } ], published: false)
    patch survey_path(s), params: { cards: [ { "type" => "open_ended", "text" => "Why?", "char_limit" => 80 } ] }.to_json,
                          headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :success
    assert_equal 80, s.reload.cards.first["char_limit"]
  end
end
