require "application_system_test_case"

# BUG-029. The consent gate's inline editor saves on a 900ms debounce, and the
# timer's closure read the element when it FIRED rather than when it was queued.
# `removeConsent` resets that same element to its default text before saving an
# empty one — so a creator who typed a word and then clicked ✕ Remove within
# 900ms got the pending timer landing afterwards with the DEFAULT consent copy,
# silently putting a live consent gate back on a Verto they had just taken it
# off. Nothing on screen showed it: the card was hidden and the CTA was back.
#
# The gate is respondent-facing and legally meaningful, so "it reappeared and
# nobody noticed" is the bad part, not the lost keystroke.
class GateRemoveRaceTest < ApplicationSystemTestCase
  def setup
    super
    @org  = Organisation.create!(name: "Studio", slug: "gr-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "Gr", email_address: "gr-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")

    @survey = @org.surveys.create!(
      title: "Gate", theme: "Safety", audience_age: "adults", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "welcome_card", "title" => "Hello" },
               { "type" => "yes_no", "cid" => "q1", "text" => "Ok?", "options" => %w[Yes No] } ],
      consent_text: "Please agree before starting."
    )
  end

  def open_editor
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_selector "[data-gate-cards-target='consentBody']", visible: :all
  end

  def gate_controller_js
    <<~JS
      const app  = window.Stimulus || window.application
      const root = document.querySelector('[data-controller~="gate-cards"]')
      const c    = app.getControllerForElementAndIdentifier(root, "gate-cards")
    JS
  end

  test "typing then immediately removing the gate leaves it removed" do
    open_editor

    execute_script(<<~JS)
      #{gate_controller_js}
      // A keystroke, then Remove inside the 900ms debounce window.
      c.consentBodyTarget.textContent = "Half-written consent copy"
      c.queueConsentSave()
      c.removeConsent()
    JS

    # Wait past the debounce, then past the save it would have made.
    Timeout.timeout(15) { sleep 0.25 until @survey.reload.consent_text.to_s.empty? }
    sleep 2

    assert_equal "", @survey.reload.consent_text.to_s,
                 "a pending keystroke timer put the consent gate back after it was removed"
  end

  test "the removal is what persists, not the default copy" do
    open_editor

    execute_script(<<~JS)
      #{gate_controller_js}
      c.consentBodyTarget.textContent = "Something the creator typed"
      c.queueConsentSave()
      c.removeConsent()
    JS

    sleep 2
    refute @survey.reload.consent_gated?,
           "the Verto should not be gating respondents after the gate was removed"
  end

  # The negative case: an ordinary debounced edit must still save, or the fix
  # would have turned the consent editor read-only.
  test "an ordinary edit still saves after the debounce" do
    open_editor

    execute_script(<<~JS)
      #{gate_controller_js}
      c.consentBodyTarget.textContent = "Updated consent wording."
      c.queueConsentSave()
    JS

    Timeout.timeout(15) { sleep 0.25 until @survey.reload.consent_text == "Updated consent wording." }
    assert_equal "Updated consent wording.", @survey.reload.consent_text
  end

  # The queued save must carry the text as it was WHEN QUEUED. Reading the
  # element at fire time is what let removeConsent's reset leak into the save.
  test "the queued save carries the text from when it was queued" do
    open_editor

    execute_script(<<~JS)
      #{gate_controller_js}
      c.consentBodyTarget.textContent = "The text at queue time."
      c.queueConsentSave()
      // Something else rewrites the element before the timer fires.
      c.consentBodyTarget.textContent = "Rewritten by someone else."
    JS

    # Wait for the value to CHANGE — it starts non-blank from the fixture, so
    # waiting on `.present?` returns before the save has landed and asserts
    # against the old value.
    Timeout.timeout(15) do
      sleep 0.25 until @survey.reload.consent_text != "Please agree before starting."
    end
    assert_equal "The text at queue time.", @survey.reload.consent_text
  end
end
