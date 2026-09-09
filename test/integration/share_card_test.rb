require "test_helper"

# The share card: three columns describing what a passed-on /play link says
# about itself, edited from a slot in the editor's card feed (the same shape as
# the thank-you slot — see thank_you_screen_test.rb) and read by the OpenGraph
# tags the player emits.
#
# The property this file exists to hold is the fallback: a Verto nobody has
# written share copy for has to unfurl exactly as it did before these columns
# existed. player_show_smoke_test.rb asserts the tags for that untouched case;
# here we assert the crossover, that writing the copy is what changes them.
class ShareCardTest < ActionDispatch::IntegrationTest
  CARDS = [
    { "type" => "welcome_card", "title" => "hi" },
    { "type" => "yes_no", "text" => "Like sport?", "options" => [ "Yes", "No" ] }
  ].freeze

  # Settings are owner-only, so this path signs in.
  def sign_in_org(suffix)
    user = User.create!(name: "U", email_address: "u-#{suffix}-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    org  = Organisation.create!(name: "Acme United", slug: "o-#{suffix}-#{SecureRandom.hex(2)}")
    org.memberships.create!(user: user, role: "admin")
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
    org
  end

  def survey_for(org, **attrs)
    org.surveys.create!(title: "T", theme: "Sports", audience_age: "all", key_insight: "x",
                        default_locale: "en", locales: [ "en" ], cards: CARDS, **attrs)
  end

  def published_survey(**attrs)
    org = Organisation.create!(name: "Acme United", slug: "o-#{SecureRandom.hex(3)}")
    survey_for(org, publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current, **attrs)
  end

  # ── Storing ───────────────────────────────────────────────────────────────

  test "update_settings stores, trims, caps and clears each share field" do
    org = sign_in_org("store")
    s   = survey_for(org)

    post survey_settings_path(s), params: {
      share_title: "  Haverley's High Street could go car-free  ",
      share_description: "  The council decides in October.  ",
      share_message: "  I just had my say — will you?  "
    }
    s.reload
    assert_equal "Haverley's High Street could go car-free", s.share_title
    assert_equal "The council decides in October.", s.share_description
    assert_equal "I just had my say — will you?", s.share_message

    post survey_settings_path(s), params: {
      share_title: "x" * (Survey::MAX_SHARE_TITLE + 40),
      share_description: "y" * (Survey::MAX_SHARE_DESCRIPTION + 40),
      share_message: "z" * (Survey::MAX_SHARE_MESSAGE + 40)
    }
    s.reload
    assert_equal Survey::MAX_SHARE_TITLE, s.share_title.length
    assert_equal Survey::MAX_SHARE_DESCRIPTION, s.share_description.length
    assert_equal Survey::MAX_SHARE_MESSAGE, s.share_message.length

    # Blank clears back to NULL rather than storing "", because NULL is what the
    # fallback readers test for.
    post survey_settings_path(s), params: { share_title: "   ", share_description: "", share_message: "  " }
    s.reload
    assert_nil s.share_title
    assert_nil s.share_description
    assert_nil s.share_message
  end

  # Share copy is distribution, not deck content — a creator rewrites how their
  # Verto is described for its whole life, so it must not join the fields that
  # lock once a Verto is live (SurveysController::SETTINGS_LOCKED_IN_USE).
  test "share copy stays editable after the Verto is published" do
    org = sign_in_org("live")
    s   = survey_for(org, publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)
    assert_predicate s, :editing_locked?

    post survey_settings_path(s), params: { share_title: "Still editable once live" }
    assert_equal "Still editable once live", s.reload.share_title
  end

  # ── The unfurl ────────────────────────────────────────────────────────────

  test "the share copy becomes the OpenGraph title and description" do
    s = published_survey(description: "The creator's editing brief.")
    s.update!(share_title: "Haverley's High Street could go car-free. Have your say.",
              share_description: "The council decides in October. Two minutes, anonymous.")

    get play_survey_path(s.publish_token)
    assert_response :success
    assert_select "meta[property='og:title'][content=?]",
                  "Haverley's High Street could go car-free. Have your say."
    assert_select "meta[property='og:description'][content=?]",
                  "The council decides in October. Two minutes, anonymous."
  end

  # The regression that matters: every Verto that already exists has these
  # columns empty, and none of them may change how they unfurl.
  test "with no share copy the tags are exactly what they were before" do
    s = published_survey(description: "Five minutes, fully anonymous.")

    get play_survey_path(s.publish_token)
    assert_response :success
    assert_select "meta[property='og:title'][content=?]", "Sports · Playverto"
    assert_select "meta[property='og:description'][content=?]", "Five minutes, fully anonymous."
  end

  test "each field falls back independently" do
    s = published_survey(description: "The brief.")
    s.update!(share_title: "Only the headline is written")

    get play_survey_path(s.publish_token)
    assert_select "meta[property='og:title'][content=?]", "Only the headline is written"
    assert_select "meta[property='og:description'][content=?]", "The brief."
  end

  test "a hostile share title cannot break out of the meta tag" do
    s = published_survey
    s.update!(share_title: %(Sports" onmouseover="alert(1)),
              share_description: "<script>alert(1)</script>")

    get play_survey_path(s.publish_token)
    assert_response :success
    assert_no_match "onmouseover=\"alert(1)\"", response.body
    assert_no_match "<script>alert(1)</script>", response.body
  end

  # ── The editor slot ───────────────────────────────────────────────────────

  test "the editor shows the CTA until share copy exists, then the card" do
    org = sign_in_org("cta")
    s   = survey_for(org)

    get survey_path(s)
    assert_response :success
    assert_select "div.gate-cta-row[data-gate-cards-target='shareCta']:not([hidden])"
    assert_select "div.gate-card-wrap[data-gate-cards-target='shareCard'][hidden]"

    s.update!(share_title: "Written")
    get survey_path(s)
    assert_select "div.gate-cta-row[data-gate-cards-target='shareCta'][hidden]"
    assert_select "div.gate-card-wrap[data-gate-cards-target='shareCard']:not([hidden])"
  end

  # The fields hold what the creator wrote, not the fallback — otherwise the
  # placeholder would be saved as real copy the first time anything else on the
  # card was edited.
  test "the editor fields are prefilled with the columns, not the fallbacks" do
    org = sign_in_org("prefill")
    s   = survey_for(org, description: "The brief.", share_title: "My headline")

    get survey_path(s)
    assert_response :success
    assert_select "div[data-gate-cards-target='shareTitle']", text: "My headline"
    assert_select "div[data-gate-cards-target='shareStory']", text: ""
    # ...but the placeholder shows what the link would say instead.
    assert_select "div[data-gate-cards-target='shareStory'][data-default-text='The brief.']"
  end

  test "any one field alone opens the card" do
    org = sign_in_org("anyone")
    %i[share_title share_description share_message].each do |field|
      s = survey_for(org, field => "something")
      get survey_path(s)
      assert_select "div.gate-card-wrap[data-gate-cards-target='shareCard']:not([hidden])",
                    { count: 1 }, "#{field} alone should open the share card"
    end
  end

  # ── Model ─────────────────────────────────────────────────────────────────

  test "duplicating a Verto carries its share copy" do
    org = sign_in_org("dup")
    s   = survey_for(org, share_title: "H", share_description: "D", share_message: "M")

    copy = s.duplicate!
    assert_equal "H", copy.share_title
    assert_equal "D", copy.share_description
    assert_equal "M", copy.share_message
  end

  test "share_message_text has no fallback — it is the creator's or absent" do
    s = published_survey(description: "The brief.")
    assert_nil s.share_message_text
    s.update!(share_message: "I just had my say")
    assert_equal "I just had my say", s.share_message_text
  end
end
