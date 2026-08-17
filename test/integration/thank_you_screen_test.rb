require "test_helper"

class ThankYouScreenTest < ActionDispatch::IntegrationTest
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

  # The player is public — created without a session so the fullscreen layout
  # renders the bare respondent view (a signed-in user would get app chrome).
  def published_survey(name: "Acme United")
    org = Organisation.create!(name: name, slug: "o-#{SecureRandom.hex(3)}")
    org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                        default_locale: "en", locales: [ "en" ], cards: CARDS,
                        publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)
  end

  test "update_settings stores custom thank-you copy and normalises the forward URL" do
    org = sign_in_org("set")
    s   = org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                              default_locale: "en", locales: [ "en" ], cards: CARDS,
                              publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)

    post survey_settings_path(s), params: {
      thankyou_title: "  You're a star ⭐  ",
      thankyou_body:  "We'll be in touch.\nSee you soon.",
      forward_url:    "example.org/thanks"
    }
    s.reload
    assert_equal "You're a star ⭐", s.thankyou_title
    assert_equal "We'll be in touch.\nSee you soon.", s.thankyou_body
    assert_equal "https://example.org/thanks", s.forward_url
    assert s.forward_url?

    # A non-http(s) value clears the CTA rather than storing something unsafe.
    post survey_settings_path(s), params: { forward_url: "javascript:alert(1)" }
    assert_nil s.reload.forward_url
    assert_not s.forward_url?
  end

  test "player renders the custom thank-you copy, a share button, and the website CTA" do
    s = published_survey
    s.update!(thankyou_title: "Big thanks!", thankyou_body: "Line one\nLine two",
              forward_url: "https://acme.example")

    get play_survey_path(s.publish_token)
    assert_response :success

    assert_select ".preview-thankyou-title", text: "Big thanks!"
    assert_select ".preview-thankyou-sub br" # the newline became a line break
    assert_match "Line one", response.body
    assert_match "Line two", response.body

    # Share button is always present; the forward CTA links out safely.
    assert_select "button[data-player-target='shareBtn']"
    assert_select "a[href='https://acme.example'][target='_blank'][rel='noopener']"
  end

  # Personalisation (%{name}/%{score}/%{max}/%{points}, with an optional
  # %{var|fallback}) is interpolated client-side in player_controller.js —
  # the server's only job is to store and render the template syntax
  # untouched, never attempt its own substitution or escape the braces away.
  test "template variable syntax in the thank-you copy round-trips and renders literally" do
    org = sign_in_org("tmpl")
    s   = org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                              default_locale: "en", locales: [ "en" ], cards: CARDS,
                              publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)

    post survey_settings_path(s), params: {
      thankyou_title: "Nice one, %{name|friend}!",
      thankyou_body:  "You scored %{score}/%{max} and earned %{points} points."
    }
    assert_equal "Nice one, %{name|friend}!", s.reload.thankyou_title
    assert_equal "You scored %{score}/%{max} and earned %{points} points.", s.thankyou_body

    get play_survey_path(s.publish_token)
    assert_response :success
    assert_select ".preview-thankyou-title", text: "Nice one, %{name|friend}!"
    assert_match "You scored %{score}/%{max} and earned %{points} points.", response.body
  end

  test "without customisation the thank-you falls back to defaults and shows no website CTA" do
    s = published_survey

    get play_survey_path(s.publish_token)
    assert_response :success

    assert_select ".preview-thankyou-title", text: I18n.t("player.thank_you_title")
    assert_select "button[data-player-target='shareBtn']"
    # No forward URL set → the website CTA renders but starts hidden (a branch
    # end screen can reveal + repoint it at its own link); share still shows.
    assert_select "a.hidden[data-player-target='forwardBtn']"
    assert_select "a[data-player-target='forwardBtn']:not(.hidden)", false
  end

  # ── The off-site link's button label ──────────────────────────────────────
  # The URL column existed and rendered on the player, but nothing in the
  # editor could set it, and the button was always the generic "Visit website".

  test "update_settings stores, caps and clears the forward label" do
    org = sign_in_org("label")
    s   = org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                              default_locale: "en", locales: [ "en" ], cards: CARDS)

    post survey_settings_path(s), params: { forward_url: "acme.example", forward_label: "  Book your place  " }
    assert_equal "Book your place", s.reload.forward_label

    post survey_settings_path(s), params: { forward_label: "x" * (Survey::MAX_END_LABEL + 25) }
    assert_equal Survey::MAX_END_LABEL, s.reload.forward_label.length

    post survey_settings_path(s), params: { forward_label: "   " }
    assert_nil s.reload.forward_label
  end

  test "the player's forward button uses the custom label, falling back to the localised default" do
    s = published_survey
    s.update!(forward_url: "https://acme.example", forward_label: "Book your place")

    get play_survey_path(s.publish_token)
    assert_select "a[data-player-target='forwardBtn']", text: /Book your place/
    assert_no_match I18n.t("player.visit_website"), css_select("a[data-player-target='forwardBtn']").first.text

    s.update!(forward_label: nil)
    get play_survey_path(s.publish_token)
    assert_select "a[data-player-target='forwardBtn']", text: /#{Regexp.escape(I18n.t("player.visit_website"))}/
  end

  test "the default end screen carries the label through to the player payload" do
    s = published_survey
    s.update!(forward_url: "https://acme.example", forward_label: "Book your place")

    screen = s.default_end_screen
    assert_equal "https://acme.example", screen["forward_url"]
    assert_equal "Book your place", screen["forward_label"]

    # A branch screen keeps its own pair — the default no longer forces nil.
    assert_nil s.reload.tap { |x| x.update!(forward_label: nil) }.default_end_screen["forward_label"]
  end

  # The actual reported gap: the editor rendered the CTA in its preview but had
  # no field to set it, so a creator could only get one by enabling Logic &
  # flows and adding a branch end screen.
  test "the editor exposes the link and label fields, prefilled" do
    org = sign_in_org("editor")
    s   = org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                              default_locale: "en", locales: [ "en" ], cards: CARDS,
                              forward_url: "https://acme.example", forward_label: "Book your place")

    get survey_path(s)
    assert_response :success
    assert_select "input[data-gate-cards-target='tyForwardUrl'][value='https://acme.example']"
    assert_select "input[data-gate-cards-target='tyForwardLabel'][value='Book your place']"
  end

  # A link with no custom copy still has to open the thank-you card, or the
  # fields that hold it would be hidden behind the "＋ Thank-you screen" CTA.
  test "a forward URL alone opens the thank-you card in the editor" do
    org = sign_in_org("open")
    s   = org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                              default_locale: "en", locales: [ "en" ], cards: CARDS,
                              forward_url: "https://acme.example")

    get survey_path(s)
    assert_select "div.gate-card-wrap[data-gate-cards-target='tyCard']:not([hidden])"
    assert_select "div.gate-cta-row[data-gate-cards-target='tyCta'][hidden]"
  end

  test "duplicating a Verto carries the forward link and its label" do
    org = sign_in_org("dup")
    s   = org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                              default_locale: "en", locales: [ "en" ], cards: CARDS,
                              forward_url: "https://acme.example", forward_label: "Book your place")

    copy = s.duplicate!
    assert_equal "https://acme.example", copy.forward_url
    assert_equal "Book your place", copy.forward_label
  end

  # duplicate! enumerates its columns explicitly, so a new column left off the
  # list vanishes silently on every Duplicate action — this pins sdgs on it.
  test "duplicating a Verto carries its SDG tags without re-deriving them" do
    org = sign_in_org("dup-sdg")
    s   = org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                              default_locale: "en", locales: [ "en" ], cards: CARDS)
    s.update_column(:sdgs, [ 4, 13 ])

    assert_equal [ 4, 13 ], s.reload.duplicate!.sdgs
  end
end
