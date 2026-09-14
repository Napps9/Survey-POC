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
    agree_to_consent_gate
  end

  PHONE = [ 393, 660 ].freeze

  def open_phone_player
    page.driver.browser.resize(width: PHONE[0], height: PHONE[1])
    open_player
  end

  # Cuprite keeps ONE browser for the whole run, so a suite that exits
  # phone-sized breaks every test scheduled after it.
  def teardown
    page.driver.browser.resize(width: 1280, height: 900)
    super
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

  # ── The logo on a phone ────────────────────────────────────────────────
  # A phone has no room above the card for the desktop masthead, so the logo
  # rides the utility bar that is already drawn there: "I was going to say
  # remove the black bar at the top as it feels weird, but maybe the Unleash
  # Football logo could sit small in the middle of the bar, so it looks like it
  # serves more of a purpose?"

  test "on a phone the logo rides the top bar, centred, and the masthead stays away" do
    attach_logo!
    open_phone_player

    assert_selector ".player-bar-logo", wait: 5
    assert_no_selector ".player-brand-header", visible: true

    box = page.evaluate_script(<<~JS)
      (() => {
        const bar  = document.querySelector(".player-lang-bar")
        const logo = document.querySelector(".player-bar-logo")
        const b = bar.getBoundingClientRect(), l = logo.getBoundingClientRect()
        return {
          barH: Math.round(b.height),
          logoH: Math.round(l.height),
          offCentre: Math.round((l.left + l.right) / 2 - (b.left + b.right) / 2),
          insideBar: l.top >= b.top - 1 && l.bottom <= b.bottom + 1
        }
      })()
    JS

    assert_operator box["offCentre"].abs, :<=, 2,
                    "the logo sits #{box['offCentre']}px off the middle of the bar"
    assert box["insideBar"],
           "the logo overhangs the bar, so it is painting over the top of the card"
    assert_operator box["barH"], :<=, 44,
                    "the bar grew to #{box['barH']}px to hold the logo — it is worth the brand " \
                    "only while it costs the card about the height it already did"
    assert_operator box["logoH"], :>=, 16, "the logo is too small to read as one"
  end

  # The bar used to be a strip of backdrop holding an invisible Test Mode
  # hatch on a Verto with one language — nothing visible at all, which is what
  # made it read as a weird black band. A logo is the first thing that gives it
  # a reason to be there.
  test "a single-language Verto's bar earns its place once there is a logo in it" do
    attach_logo!
    open_phone_player

    assert_equal [ "en" ], @survey.verto_locales
    assert_no_selector ".lang-switcher"
    assert_selector ".player-bar-logo"
    assert_operator page.evaluate_script(
      "Math.round(document.querySelector('.player-lang-bar').getBoundingClientRect().height)"
    ), :>=, 24, "the bar collapsed and took the logo with it"
  end

  test "with no logo the phone bar collapses exactly as it did before" do
    open_phone_player

    assert page.has_no_css?(".player-bar-logo", visible: :all, wait: 2),
           "an org with no logo gets no logo — not an empty slot holding the bar open"
    assert_equal 0, page.evaluate_script(
      "Math.round(document.querySelector('.player-lang-bar').getBoundingClientRect().height)"
    ), "the bar is holding space open for a logo that does not exist"
  end

  # Two copies of the same mark on one screen. The bar's is the one a
  # respondent has seen all the way through the deck, so it wins — on the
  # welcome card, where the request was "the logo somewhere here", and on the
  # thank-you card, which already had one.
  test "the welcome card drops its own logo when the bar is carrying one" do
    attach_logo!
    open_phone_player

    assert_selector ".player-bar-logo", visible: true, wait: 5
    assert_no_selector ".preview-card.active .split-right-logo", visible: true
  end

  test "on a desktop the welcome card keeps its own logo and the bar has none" do
    attach_logo!
    open_player

    assert_selector ".player-brand-header img", wait: 5
    assert_no_selector ".player-bar-logo", visible: true
    assert_selector ".preview-card.active .split-right-logo img", visible: true
  end

  test "the thank-you card drops its own logo when the bar is carrying one" do
    attach_logo!
    open_phone_player
    click_button "Next"
    find('.preview-card.active li[role="radio"]', match: :first).click
    click_button "Submit"

    assert_selector ".preview-thankyou", visible: true, wait: 10
    assert_selector ".player-bar-logo", visible: true
    assert_no_selector ".player-thankyou-logo", visible: true
    # The attribution is untouched, as ever.
    assert_selector ".play-powered .play-powered-mark"
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
