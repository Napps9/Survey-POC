require "application_system_test_case"

# The tick ceiling, in the two places it is actually a behaviour rather than a
# stored number: the respondent's card, where the extra tap has to be refused
# and the rest visibly go inert, and the creator's panel, where the range of
# offered numbers has to follow the card's own option list.
#
# Neither can be reached below the browser. picker_controller is where the
# refusal lives, and the picker's buttons don't exist in any server template —
# they are built from the option count at the moment the panel is opened.
class MaxChoicesSystemTest < ApplicationSystemTestCase
  OPTIONS = %w[Trains Buses Cycling Walking Driving].freeze

  def setup
    super
    @org  = Organisation.create!(name: "Studio", slug: "mcs-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "Mcs", email_address: "mcs-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")
  end

  def survey_with(max_choices: nil)
    card = { "type" => "select_many", "cid" => "q1", "text" => "How do you get around?",
             "options" => OPTIONS.dup }
    card["max_choices"] = max_choices if max_choices
    @org.surveys.create!(
      title: "Travel", theme: "Travel", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ], cards: [ card ]
    )
  end

  # ── The respondent ────────────────────────────────────────────────────────

  test "the cap refuses the extra tap, dims the rest, and frees up on an untick" do
    survey = survey_with(max_choices: 2)
    survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)

    visit "/play/#{survey.publish_token}"
    dismiss_cookie_banner
    assert_selector ".preview-card.active", wait: 5
    # The how-to line is the only place the rule is stated — the refusal below
    # is silent, so if this is wrong the respondent is simply confused.
    # .q-eyebrow is text-transform: uppercase, and Capybara reads what is PAINTED.
    assert_selector ".preview-card.active .q-eyebrow", text: I18n.t("card.eyebrow_max", n: 2).upcase

    pick("Trains")
    pick("Buses")
    assert_selector ".choice-list[data-at-cap='true']"

    # The refusal, both halves of it.
    #
    # A pointer never reaches the option at all — the dimming rule takes its
    # pointer events with it, which is why a real click here raises rather than
    # selecting (Cuprite reports the <ul> underneath as the element actually at
    # those coordinates). Asserting the property is the readable version of the
    # same fact.
    assert_equal "none", pointer_events_of("Cycling")

    # A KEYBOARD is the path CSS cannot refuse: Enter on a focused checkbox goes
    # straight to picker#pickOnKey. This is the one that needs the guard in the
    # controller, and the only reason it is there.
    press_enter_on("Cycling")
    assert_selector ".choice-list-item[data-selected='true']", count: 2
    assert_equal "false", item("Cycling")[:"data-selected"]

    # Inert, and saying so. The dimming is the visible half; aria-disabled is
    # the half a screen reader gets, and neither is any use without the other.
    assert_equal "true", item("Cycling")[:"aria-disabled"]
    assert_in_delta 0.4, opacity_of("Cycling"), 0.01,
                    "the compiled stylesheet has to carry the [data-at-cap] rule — " \
                    "run bin/rails tailwindcss:build if this is the only failure"
    assert_nil item("Trains")[:"aria-disabled"], "a pick you have made is never disabled — " \
                                                 "unticking it is the way back under the cap"
    assert_in_delta 1.0, opacity_of("Trains"), 0.01

    # Giving one up frees the slot, which is what makes the cap navigable.
    pick("Trains")
    assert_selector ".choice-list[data-at-cap='false']"
    pick("Cycling")
    assert_selector ".choice-list-item[data-selected='true']", count: 2

    find(".preview-btn-finish").click
    assert_selector ".preview-thankyou.active", wait: 8

    stored = wait_for_answer(survey)
    assert_equal %w[Buses Cycling], stored.sort,
                 "exactly the two that survived the cap, and nothing the refused tap left behind"
  end

  test "an uncapped card is untouched" do
    survey = survey_with
    survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)

    visit "/play/#{survey.publish_token}"
    dismiss_cookie_banner
    assert_selector ".preview-card.active", wait: 5
    assert_selector ".preview-card.active .q-eyebrow", text: I18n.t("card.eyebrow.select_many").upcase

    OPTIONS.each { |o| pick(o) }
    assert_selector ".choice-list-item[data-selected='true']", count: OPTIONS.size
    assert_no_selector ".choice-list[data-at-cap='true']"
  end

  # ── The creator ───────────────────────────────────────────────────────────

  test "the picker offers 2…N off the card's own options, and the how-to line follows" do
    survey = survey_with
    sign_in_as(@user)
    visit survey_path(survey)
    dismiss_cookie_banner

    find("[data-card-cid='q1'] .card-num-pill").click
    assert_selector ".editor-grid.is-panel-open"

    picker = find("[data-survey-editor-target='maxChoicesPicker']")
    assert_equal [ "2", "3", "4", I18n.t("card.max_choices_all") ],
                 picker.all(".response-scale-btn").map(&:text),
                 "five options means 2, 3 or 4 — a fifth would be no limit, which is what All is"
    assert_equal "true",
                 picker.find(".response-scale-btn[data-max-choices='0']")[:"aria-pressed"],
                 "no stored key is the default, and the default has to show as chosen"

    picker.find(".response-scale-btn[data-max-choices='3']").click
    assert_selector "[data-card-cid='q1'][data-card-max-choices='3']"
    assert_selector "[data-card-cid='q1'] .q-eyebrow", text: I18n.t("card.eyebrow_max", n: 3).upcase
    # The editor card is the player's markup, so the preview enforces the same
    # rule from the same attribute rather than waiting for a reload to show it.
    assert_selector "[data-card-cid='q1'] .choice-list[data-picker-max-value='3']"

    # The autosave has to carry it, which is the step the DOM round-trip breaks
    # for anything the editor doesn't re-render.
    wait_for { survey.reload.cards.first["max_choices"] == 3 }

    # And "All" takes it back off — as an absent key, not as the number 5, so
    # a sixth option later still means six.
    picker.find(".response-scale-btn[data-max-choices='0']").click
    assert_selector "[data-card-cid='q1'] .q-eyebrow", text: I18n.t("card.eyebrow.select_many").upcase
    assert_selector "[data-card-cid='q1'] .choice-list[data-picker-max-value='0']"
    assert_no_selector "[data-card-cid='q1'] .choice-list[data-at-cap='true']"
    wait_for { !survey.reload.cards.first.key?("max_choices") }
  end

  private

  def item(label)
    find(".preview-card.active .choice-list-item", text: label)
  end

  def pick(label)
    item(label).click
  end

  # Focus through the DOM and type at the browser rather than through
  # Element#send_keys, which clicks the node first to focus it — and a click is
  # the one thing this option can't receive.
  def press_enter_on(label)
    page.execute_script("arguments[0].focus()", item(label))
    page.driver.browser.keyboard.type(:Enter)
  end

  def pointer_events_of(label)
    computed(label, "pointerEvents")
  end

  def opacity_of(label)
    computed(label, "opacity").to_f
  end

  def computed(label, property)
    evaluate_script(<<~JS)
      (() => {
        const el = Array.from(document.querySelectorAll(".preview-card.active .choice-list-item"))
          .find(n => n.textContent.includes(#{label.to_json}))
        return getComputedStyle(el).#{property}
      })()
    JS
  end

  def wait_for(seconds: 10)
    deadline = Time.current + seconds
    loop do
      return true if yield
      raise "condition never came true" if Time.current > deadline
      sleep 0.2
    end
  end

  def wait_for_answer(survey)
    value = nil
    wait_for { value = survey.responses.reload.first&.answers&.dig("0", "value"); value.present? }
    Array(value)
  end
end
