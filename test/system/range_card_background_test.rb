require "application_system_test_case"

# Animation background (2.10-ish: card["media_bg"]) already applied to a
# range card once _syncAnimationBg ran — _cardAnimates checks
# `card.dataset.cardType === "range"` — but nothing on a range card's panel
# ever called media-picker#open to get there: the range branch of
# _split_left.html.erb only rendered the reactive Lottie plus a
# "Change animation" CTA wired to the separate animation-picker modal. This
# suite exercises the new second CTA that opens the ordinary media picker for
# just the per-card settings.
class RangeCardBackgroundTest < ApplicationSystemTestCase
  def setup
    super
    @user = User.create!(name: "U", email_address: "range-bg-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @org = Organisation.create!(name: "O", slug: "range-bg-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(
      title: "Range BG", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "welcome_card", "title" => "hi" },
        { "type" => "range", "cid" => "r1", "text" => "How likely?", "options" => %w[0 1 2 3 4 5 6 7 8 9 10] },
        { "type" => "open_ended", "cid" => "o1", "text" => "When were you born?",
          "lottie" => "/verto_library/anim/example.json" }
      ]
    )
  end

  def lottie_card
    find(".survey-card-wrap[data-card-cid='o1']")
  end

  def range_card
    find(".survey-card-wrap[data-card-type='range']")
  end

  def open_range_background_settings
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_text "How likely?"
    within(range_card) { find(".add-bg-fab").click }
  end

  test "the range card's panel offers both a Change animation and a Background CTA" do
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_text "How likely?"

    within(range_card) do
      assert_selector ".add-animation-fab", text: "Change animation"
      assert_selector ".add-bg-fab", text: "Background"
    end
  end

  test "Background opens the media picker showing only the Animation background settings" do
    open_range_background_settings

    assert_selector ".media-modal-backdrop", visible: true
    assert_selector "[data-media-picker-target='animBgSection']", visible: true
    # No card-level photo/video slot to swap on a range card — the source
    # tabs/panes and "Remove current media" have nothing to act on.
    assert_no_selector ".media-modal-tabs", visible: true
    assert_no_selector "[data-media-picker-target='pane']", visible: true
    assert_no_selector "[data-media-picker-target='clearBtn']", visible: true
    # animate_asset is explicitly excluded for range cards (its own reaction
    # set already animates) — the toggle must stay hidden here too.
    assert_no_selector "[data-media-picker-target='animateAssetSection']", visible: true
    # Colour/asset settings here all save live — a permanently-disabled Apply
    # with nothing to ever enable it read as "did my change not stick?" (a
    # real report from actually using this). Hidden until there is something
    # to apply, i.e. after "Use an image" is picked.
    assert_no_selector "[data-media-picker-target='applyBtn']", visible: true
  end

  test "setting a background colour on a range card saves it live, no Apply needed" do
    open_range_background_settings

    # <input type="color"> isn't reliably typeable via Capybara's set — drive
    # it directly and dispatch the same "input" event setAnimBgColor listens
    # for, exactly like this suite's live-apply (no Apply button) is meant to
    # exercise.
    evaluate_script(<<~JS)
      (() => {
        const el = document.querySelector("[data-media-picker-target='animBgColor']")
        el.value = "#ff00aa"
        el.dispatchEvent(new Event("input", { bubbles: true }))
      })()
    JS

    assert_equal "#ff00aa", evaluate_script(<<~JS)
      JSON.parse(document.querySelector(".survey-card-wrap[data-card-type='range']").dataset.cardMediaBg).color
    JS
  end

  test "Use an image on a range card's background brings the source tabs back" do
    open_range_background_settings
    find("[data-media-picker-target='animBgSection'] button", text: "Use an image").click

    assert_selector ".media-modal-tabs", visible: true
    assert_selector "[data-media-picker-target='pane'][data-pane='library']", visible: true
    # Now there's something a pick could apply to — Apply comes back.
    assert_selector "[data-media-picker-target='applyBtn']", visible: true
  end
  # A Lottie is the one medium that can be TRANSPARENT, so what sits behind it
  # is a real design decision — and this panel offered no way to make it ("I
  # need the Change Background option here for when we upload transparent
  # lottie files"). Only the ENTRY POINT was missing: media-picker's
  # _cardAnimates already returns true for any card carrying a lottie, not just
  # for range, so the Animation background section has been in that modal all
  # along with nothing on this panel calling it.
  test "a lottie card offers Background alongside Change media" do
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_text "When were you born?"

    within(lottie_card) do
      assert_selector ".add-media-fab", text: "Change media"
      assert_selector ".add-bg-fab",    text: "Background"
    end
  end

  test "a lottie card's Background CTA opens the animation background settings" do
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_text "When were you born?"
    within(lottie_card) { find(".add-bg-fab").click }

    assert_selector ".media-modal-backdrop", visible: true
    assert_selector "[data-media-picker-target='animBgSection']", visible: true
  end

  # Scoped to lotties on purpose: a photo or a video is opaque, so a background
  # behind one is a control that does nothing.
  test "a plain image card is not given a Background CTA" do
    @survey.update_columns(cards: @survey.cards + [
      { "type" => "rating", "cid" => "img1", "text" => "Rate it", "image" => "/nope.jpg",
        "options" => [ "Poor", "Great" ] }
    ])
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_text "Rate it"

    within(find(".survey-card-wrap[data-card-cid='img1']")) do
      assert_selector ".add-media-fab"
      # By its label, the way this file's own lottie test identifies it — the
      # .add-bg-fab CLASS is shared styling that "Adjust crop" (a control a
      # photo card is SUPPOSED to have) borrows too.
      assert_no_selector ".add-bg-fab", text: "Background"
    end
  end

  # Both FABs are `position: absolute` with a left:50% translate of their own —
  # correct while each is its panel's only control, wrong the moment they share
  # a row. Unreset, the second lands on top of the first and the row renders as
  # one button with another hidden underneath it.
  test "the two CTAs sit side by side rather than stacked" do
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_text "When were you born?"

    boxes = page.evaluate_script(<<~JS)
      (() => {
        const row = document.querySelector(".survey-card-wrap[data-card-cid='o1'] .split-left-cta-row")
        if (!row) return null
        return Array.from(row.children).map(el => {
          const r = el.getBoundingClientRect()
          return { left: Math.round(r.left), right: Math.round(r.right), w: Math.round(r.width) }
        })
      })()
    JS

    assert_equal 2, boxes&.size, "expected two CTAs in the row, got #{boxes.inspect}"
    assert_operator boxes[0]["right"], :<=, boxes[1]["left"] + 1,
                    "the CTAs overlap (#{boxes.inspect}) — one is still absolutely positioned " \
                    "inside the row, so it is painted on top of the other."
  end
end
