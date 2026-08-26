require "test_helper"

# The two tokenomics lines on the points intro are per-Verto copy now, and
# the token-type pills row between them is gone.
#
# Feedback 17: "being able to edit both of the tokenomics text per verto
# would be useful, to add own context here about mountain and steps etc. I
# think we can lose the 'steps' lozenge from here, as we have it at the
# bottom of screen for players." The pills previewed the deck's token types
# on the intro; the player's own HUD chip already names the token, so the
# intro was saying it twice.
class TokenNotesTest < ActionDispatch::IntegrationTest
  CARDS = [
    { "type" => "welcome_card", "cid" => "w", "text" => "Welcome" },
    { "type" => "yes_no", "cid" => "q", "text" => "Q", "options" => [ "Yes", "No" ] }
  ].freeze

  def survey(tokens_note: nil, leaderboard_note: nil)
    org = Organisation.create!(name: "O", slug: "tn-#{SecureRandom.hex(3)}")
    org.surveys.create!(
      title: "T", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ], cards: CARDS,
      tokenisation_enabled: true, leaderboard_enabled: true,
      tokens_note: tokens_note, leaderboard_note: leaderboard_note,
      token_types: [ { "id" => "steps", "icon" => "🥾", "name" => "Steps" } ],
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current
    )
  end

  def admin_for(org)
    user = User.create!(name: "U", email_address: "u-#{SecureRandom.hex(3)}@test.com",
                        password: "verylongpassword")
    org.memberships.create!(user: user, role: "admin")
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
    user
  end

  test "custom tokenomics copy renders on the intro, and the default returns when cleared" do
    s = survey(tokens_note: "Every step up this mountain earns you points.",
               leaderboard_note: "The fastest climbers make the summit board!")
    get "/play/#{s.publish_token}"

    assert_response :success
    assert_includes response.body, "Every step up this mountain earns you points.",
                    "the custom points note is not on the intro — tokens_note_text is not " \
                    "being read where the hardcoded i18n used to be"
    assert_includes response.body, "The fastest climbers make the summit board!"

    s.update_columns(tokens_note: nil, leaderboard_note: nil)
    get "/play/#{s.publish_token}"

    # html_escape, because the default copy contains an apostrophe and the
    # body carries it as &#39; — the raw string never matches.
    assert_includes response.body, ERB::Util.html_escape(I18n.t("player.tokens_welcome_note")),
                    "a blank note must fall back to the locale default, not to nothing — " \
                    "same contract as compare_note"
    assert_includes response.body, ERB::Util.html_escape(I18n.t("player.leaderboard_teaser"))
  end

  test "the token-type pills row is gone from the intro" do
    s = survey

    get "/play/#{s.publish_token}"

    assert_response :success
    refute_includes response.body, "welcome-intake-token-types",
                    "the token-type pills are back on the points intro. The owner asked for " \
                    "the 'Steps' lozenge to go — the player's HUD chip already names the " \
                    "token, so the intro was saying it twice."
    # The notes themselves stay; only the pills between them went.
    assert_includes response.body, "welcome-intake-tokens-note"
  end

  test "update_settings stores and clears both notes" do
    s = survey
    admin_for(s.organisation)

    post survey_settings_path(s), params: {
      tokens_note: "  Climb for points.  ", leaderboard_note: "  Summit board awaits.  "
    }

    assert_equal "Climb for points.", s.reload.tokens_note, "stored un-stripped or not at all"
    assert_equal "Summit board awaits.", s.leaderboard_note

    post survey_settings_path(s), params: { tokens_note: "   ", leaderboard_note: "" }

    assert_nil s.reload.tokens_note,
               "blank must clear to nil so the locale default returns — an empty string " \
               "would render an empty pill instead"
    assert_nil s.leaderboard_note
  end

  # ── Both limits, on screen ─────────────────────────────────────────────────
  # The 200-char cap has always been enforced, but it was the only number a
  # creator could find and it is the less useful of the two: each note renders
  # as a single pill on the intro, so it stops FITTING (about 120) long before
  # it stops SAVING. Showing one limit taught the wrong one.

  test "the cap is a named constant, enforced on the way in" do
    s = survey
    admin_for(s.organisation)

    post survey_settings_path(s), params: { tokens_note: "x" * (Survey::MAX_NOTE + 50) }

    assert_equal Survey::MAX_NOTE, s.reload.tokens_note.length,
                 "the note must be cut to MAX_NOTE server-side — maxlength is a courtesy, not a guard"
    assert_operator Survey::RECOMMENDED_NOTE, :<, Survey::MAX_NOTE,
                    "the recommended width has to sit below the cap or there is nothing to advise about"
  end

  test "the editor shows both limits and the split-to-a-card advice" do
    s = survey
    admin_for(s.organisation)

    get survey_path(s)
    assert_response :success

    assert_match 'data-note-limit-recommended-value="120"', response.body
    assert_match 'data-note-limit-max-value="200"', response.body
    assert_match I18n.t("editor.note_limit_split_hint", n: Survey::RECOMMENDED_NOTE), response.body

    counter = I18n.t("js.editor.note_limit_count")
    %w[%{n} %{recommended} %{max}].each do |slot|
      assert_includes counter, slot,
                      "the counter must name the count AND both limits — it is the whole point of the string"
    end
  end
end
