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

  # The card used to borrow .preview-thankyou-card and read as three identical
  # labelled fields. Both were wrong: borrowing the player's card class is what
  # let the end screen's desktop grid pick it up and deal the fields into a 2x2,
  # and "three fields" hid that two of them are the unfurl a recipient reads
  # while the third is the line the respondent sends.
  test "the share card is drawn as the link preview it configures" do
    org = sign_in_org("unfurl")
    s   = survey_for(org, share_title: "Written")

    get survey_path(s)
    assert_response :success

    assert_select ".unfurl-mock", 1
    assert_select ".unfurl-mock.preview-thankyou-card", 0,
                  "it must not borrow the player's card class again — that is what scrambled it"
    assert_select ".gate-share-card", 0

    # The headline and story are edited inside the bubble...
    assert_select ".unfurl-bubble div[data-gate-cards-target='shareTitle']", 1
    assert_select ".unfurl-bubble div[data-gate-cards-target='shareStory']", 1
    assert_select ".unfurl-bubble img.unfurl-thumb", 1
    # ...and the message the respondent sends is deliberately outside it.
    assert_select ".unfurl-bubble [data-gate-cards-target='shareMessage']", 0
    assert_select "div[data-gate-cards-target='shareMessage']", 1

    # The counters moved out of the labels but must still be there to paint.
    %w[shareTitleCount shareStoryCount shareMessageCount].each do |target|
      assert_select "[data-gate-cards-target='#{target}']", 1
    end
  end

  # The mock draws Survey#share_image_path, which is the same value the meta tag
  # emits — so the preview cannot drift from what a recipient actually sees.
  test "the mock's thumbnail is the real og:image" do
    org = sign_in_org("thumb")
    s   = survey_for(org, share_title: "Written")

    get survey_path(s)
    assert_select "img.unfurl-thumb" do |img|
      assert_equal s.share_image_path, img.first["src"]
    end
  end

  # ── The preview picture ───────────────────────────────────────────────────
  # It used to be the one part of the unfurl a creator could look at and not
  # change: Survey#share_image_path walked gate image → backdrop → first card →
  # library and the editor drew whatever came out. Fine as a guarantee, poor as
  # a decision — the only thing a stranger sees before reading a word went to
  # whichever card happened to come first.

  test "the thumbnail is the picker's trigger and the panel is there to open" do
    org = sign_in_org("picker")
    s   = survey_for(org, share_title: "Written")

    get survey_path(s)
    assert_response :success

    assert_select "button.unfurl-thumb-btn[aria-expanded='false']" do
      assert_select "img.unfurl-thumb[data-gate-cards-target='shareImage']", 1
    end
    assert_select ".share-image-picker[hidden]", 1
    # Delegated on the grid: the tiles are built in JS from the live feed, and
    # an action attribute on a fresh element is bound on Stimulus's schedule.
    assert_select ".share-image-grid[data-action='click->gate-cards#pickShareImage']", 1
  end

  # "Let it pick" is only a real choice if the creator can see what it picks,
  # so the Automatic tile carries the derivation's own answer — which is NOT
  # the same as the current one once a pick is in place.
  test "the panel carries what Automatic would restore, not the current pick" do
    org  = sign_in_org("auto")
    card = "https://images.pexels.com/photos/3/card.jpg"
    s    = survey_for(org, cards: [ { "type" => "yes_no", "text" => "Q", "image" => card } ],
                           share_image: "https://images.pexels.com/photos/9/picked.jpg")

    get survey_path(s)
    assert_select ".share-image-picker[data-auto-url=?]", card
    assert_select ".share-image-picker[data-current=?]", s.share_image
    assert_select "img.unfurl-thumb[src=?]", s.share_image
  end

  # The tiles are labelled in JS, where the card number is the only thing
  # known — so the wording travels as a template rather than as a finished
  # string, and the placeholder has to survive the trip through I18n.
  test "the card label reaches the panel as a template with its placeholder" do
    org = sign_in_org("label")
    s   = survey_for(org, share_title: "Written")

    get survey_path(s)
    assert_select ".share-image-picker[data-card-label=?]", "Card %{number}"
  end

  test "update_settings stores a picked image and clears it back to automatic" do
    org  = sign_in_org("pick")
    s    = survey_for(org)
    pick = "https://images.pexels.com/photos/9/picked.jpg"

    post survey_settings_path(s), params: { share_image: pick }
    assert_equal pick, s.reload.share_image
    assert_equal pick, s.share_image_path

    post survey_settings_path(s), params: { share_image: "" }
    assert_nil s.reload.share_image
    assert_equal s.default_share_image_path, s.share_image_path
  end

  # sanitize_image_url accepts a capped data: URL — right for a card panel,
  # wrong here. og:image is fetched by a crawler, and storing base64 would
  # leave the creator admiring a thumbnail no chat app ever renders.
  test "update_settings refuses an image og:image could not carry" do
    org = sign_in_org("refuse")
    s   = survey_for(org)
    png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

    post survey_settings_path(s), params: { share_image: "data:image/png;base64,#{png}" }
    assert_nil s.reload.share_image

    post survey_settings_path(s), params: { share_image: "https://evil.example.com/x.jpg" }
    assert_nil s.reload.share_image
  end

  # Distribution, like the copy it sits with — a creator changes how their
  # Verto presents itself for its whole life, live or not.
  test "the preview picture stays editable after the Verto is published" do
    org  = sign_in_org("livepic")
    s    = survey_for(org, publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)
    pick = "https://images.pexels.com/photos/9/picked.jpg"
    assert_predicate s, :editing_locked?

    post survey_settings_path(s), params: { share_image: pick }
    assert_equal pick, s.reload.share_image
  end

  test "a picked image reaches og:image" do
    pick = "https://images.pexels.com/photos/9/picked.jpg"
    s = published_survey(background_image: "https://images.pexels.com/photos/1/backdrop.jpg",
                         share_image: pick)

    get "/play/#{s.publish_token}"
    assert_response :success
    assert_select "meta[property='og:image'][content=?]", pick
    assert_select "meta[name='twitter:image'][content=?]", pick
  end

  # A creator who has only picked the picture has still made a decision about
  # this link, and collapsing the card behind the CTA would hide it.
  test "a picked image alone opens the share card" do
    org = sign_in_org("openpic")
    s   = survey_for(org, share_image: "https://images.pexels.com/photos/9/picked.jpg")

    get survey_path(s)
    assert_select "div.gate-card-wrap[data-gate-cards-target='shareCard']:not([hidden])", 1
  end

  # ── The tags ──────────────────────────────────────────────────────────────

  # Social recruitment is a real distribution channel, and a link with no
  # picture is a line of grey text beside everyone else's cards. So this is a
  # guarantee rather than a nicety: EVERY Verto unfurls with an image.
  test "every Verto emits an absolute og:image, imagery or none" do
    with_imagery = published_survey(background_image: "https://images.pexels.com/photos/1/p.jpg")
    without      = published_survey

    [ with_imagery, without ].each do |s|
      get "/play/#{s.publish_token}"
      assert_response :success

      src = css_select("meta[property='og:image']").first&.[]("content")
      assert src.present?, "og:image missing for #{s.id} — the fallback exists so this cannot happen"
      assert_match %r{\Ahttps?://}, src, "og:image must be absolute, got #{src.inspect}"
      assert_equal src, css_select("meta[name='twitter:image']").first&.[]("content")
      assert_equal "summary_large_image",
                   css_select("meta[name='twitter:card']").first&.[]("content")
    end
  end

  # The editor promises "written as the respondent, in their voice" and "the
  # link is added automatically". The share sheet was getting document.title and
  # the URL and nothing else, so both the headline and this line went nowhere.
  test "the creator's share copy reaches the share sheet" do
    s = published_survey(share_title: "A headline", share_message: "Have a go at this")

    get "/play/#{s.publish_token}"
    assert_select "[data-player-share-title-value='A headline']"
    assert_select "[data-player-share-text-value='Have a go at this']"
  end

  test "a Verto with no message sends no text, rather than an invented one" do
    s = published_survey

    get "/play/#{s.publish_token}"
    assert_select "[data-player-share-text-value='']"
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
    org  = sign_in_org("dup")
    pick = "https://images.pexels.com/photos/9/picked.jpg"
    s    = survey_for(org, share_title: "H", share_description: "D", share_message: "M",
                           share_image: pick)

    copy = s.duplicate!
    assert_equal "H", copy.share_title
    assert_equal "D", copy.share_description
    assert_equal "M", copy.share_message
    # The copy carries the same cards, backdrop and gate image, so the pick
    # still points at a picture the copy itself has.
    assert_equal pick, copy.share_image
  end

  test "share_message_text has no fallback — it is the creator's or absent" do
    s = published_survey(description: "The brief.")
    assert_nil s.share_message_text
    s.update!(share_message: "I just had my say")
    assert_equal "I just had my say", s.share_message_text
  end
end
