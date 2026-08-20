require "application_system_test_case"

# "If no logo is uploaded we simply won't show a logo" — everywhere.
#
# brand_logo_tag used to substitute the Playverto wordmark, which put OUR mark
# in the space reserved for the publishing organisation's: above their deck,
# and on the thank-you card directly above the "Powered by Playverto" line
# that is the actual attribution, so it appeared twice. These pin both halves —
# that the borrowed mark is gone, AND that the real attribution stayed.
class BrandLogoAbsentTest < ApplicationSystemTestCase
  CARDS = [
    { "type" => "welcome_card", "title" => "Welcome" },
    { "type" => "multiple_choice", "cid" => "c1", "text" => "Pick one",
      "options" => %w[Red Blue] }
  ].freeze

  def setup
    super
    @user = User.create!(name: "U", email_address: "logo-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @org  = Organisation.create!(name: "Bare Co", slug: "bare-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(title: "NoLogo", theme: "Th", audience_age: "adults",
                                   key_insight: "k", default_locale: "en", locales: [ "en" ],
                                   cards: CARDS)
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
  end

  def attach_logo!
    @org.logo.attach(io: StringIO.new(png_bytes), filename: "l.png", content_type: "image/png")
  end

  # A real 1x1 PNG — Active Storage stores whatever it is given, but the editor
  # preview actually paints this one, so it has to decode.
  def png_bytes
    Base64.decode64(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )
  end

  def open_player
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    click_button "Agree & continue" if has_button?("Agree & continue", wait: 3)
  end

  test "an org with no logo gets no masthead, and no empty band where it was" do
    open_player
    assert_no_selector ".player-brand-header"

    # The wrapper is skipped entirely rather than rendered empty: its own 18px
    # of padding would otherwise hold a blank band open above the deck.
    assert_no_selector ".player-brand-header", visible: :all
  end

  test "an org WITH a logo still gets its masthead" do
    attach_logo!
    open_player
    assert_selector ".player-brand-header img"
  end

  # The half most likely to be broken by a later tidy-up: removing our wordmark
  # from the logo slot must not take the attribution line with it.
  test "the thank-you screen keeps Powered by Playverto but shows no org logo" do
    open_player
    click_button "Next"
    find('.preview-card.active li[role="radio"]', match: :first).click
    click_button "Submit"

    assert_selector ".preview-thankyou", visible: true, wait: 10
    # The org's own logo slot is empty...
    assert_no_selector ".player-thankyou-logo"
    # ...but the attribution at the foot of the card is untouched. It is a
    # plain image_tag on playverto.svg, deliberately independent of
    # brand_logo_tag — assert the MARK, not the words, because "Powered by" is
    # the translated half and the wordmark is the half that carries the brand.
    assert_selector ".play-powered .play-powered-mark"
    assert_text "Powered by"
  end

  # The regression guard for the one silent failure in this change.
  #
  # logo_uploader#_setPreview used to find the existing <img> and re-point its
  # src, which was safe only while brand_logo_tag ALWAYS rendered one (falling
  # back to the wordmark). With no logo there is now no <img> in that slot at
  # all, so a "find it and set src" would find nothing and do nothing: the
  # upload would succeed server-side while the preview stayed empty — looking
  # exactly like a failed upload. _setPreview creates and destroys the tag
  # instead, and this is what proves it.
  test "uploading a logo paints the editor preview even when there was none" do
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner

    slot = find("[data-logo-uploader-target='preview']", visible: :all)
    assert slot.has_no_css?("img", visible: :all, wait: 2),
           "the slot should start empty for an org with no logo"

    path = Rails.root.join("tmp", "brand_logo_upload_#{SecureRandom.hex(4)}.png")
    File.binwrite(path, png_bytes)
    begin
      find("[data-logo-uploader-target='input']", visible: false).set(path.to_s)
      # The PATCH is async; the <img> appearing IS the thing under test.
      # visible: :all — the Design panel this slot lives in is collapsed by
      # default, so the tag's presence and its src are what matter here, not
      # whether it happens to be on screen.
      assert_selector "[data-logo-uploader-target='preview'] img", visible: :all, wait: 10

      src = page.evaluate_script(
        "document.querySelector(\"[data-logo-uploader-target='preview'] img\").getAttribute('src')"
      )
      assert_includes src.to_s, "/rails/active_storage/",
                      "the preview <img> was created but never pointed at the uploaded blob — " \
                      "_setPreview built the tag and skipped the src"
    ensure
      FileUtils.rm_f(path)
    end
  end
end
