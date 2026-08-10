require "application_system_test_case"

# The contact form on a sideways phone (844×390). Before the fix nothing gave
# .contact-form-wrap's container height or overflow, so with ~390px to work in
# the five stacked rows clipped at BOTH ends — the title pushed off the top,
# the privacy note off the bottom — with no scroll path to reach either. The
# fix adds the contact form to the same scroll-container selector sets the
# list types use, so this pins the resulting geometry, not the CSS text.
class ContactFormSidewaysTest < ApplicationSystemTestCase
  CARDS = [
    { "type" => "welcome_card", "title" => "Welcome" },
    { "type" => "contact_form", "cid" => "c1", "text" => "Stay in touch" }
  ].freeze

  SIDEWAYS = [ 844, 390 ].freeze
  # Cuprite keeps one browser for the whole run; leaving it phone-sized breaks
  # whatever desktop-layout test happens to run next (player_footer_test's
  # documented trap).
  DESKTOP = [ 1280, 900 ].freeze

  def setup
    super
    @org    = Organisation.create!(name: "O", slug: "side-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(title: "Contact", theme: "Th", audience_age: "adults",
                                   key_insight: "k", default_locale: "en", locales: [ "en" ],
                                   cards: CARDS)
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
  end

  def teardown
    page.driver.browser.resize(width: DESKTOP[0], height: DESKTOP[1])
    super
  end

  def open_contact_card
    page.driver.browser.resize(width: SIDEWAYS[0], height: SIDEWAYS[1])
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    click_button "Agree & continue" if has_button?("Agree & continue", wait: 3)
    click_button "Next" # past the welcome card
    assert_selector ".preview-card.active .contact-form-wrap", wait: 5
  end

  def scroller_metrics
    evaluate_script(<<~JS)
      (() => {
        const wrap = document.querySelector('.preview-card.active .contact-form-wrap')
        const box  = wrap.parentElement // the .mt-2 scroll container
        return { scrollHeight: box.scrollHeight, clientHeight: box.clientHeight,
                 overflowY: getComputedStyle(box).overflowY }
      })()
    JS
  end

  test "the form overflows into a real scroll container instead of clipping" do
    open_contact_card
    m = scroller_metrics

    assert_equal "auto", m["overflowY"],
      "the form's container must be a scroller, not an overflow:hidden clip"
    assert_operator m["scrollHeight"], :>, m["clientHeight"],
      "at 390px tall the form MUST overflow — equal heights would mean the " \
      "container grew unbounded and is itself being clipped by the card"
  end

  test "the title is on screen at scroll-top and the tail is reachable by scrolling" do
    open_contact_card

    visible = evaluate_script(<<~JS)
      (() => {
        const title = document.querySelector('.preview-card.active .q-header')
        const r = title.getBoundingClientRect()
        return r.top >= 0 && r.bottom <= window.innerHeight
      })()
    JS
    assert visible, "the question title must not be pushed off the top at scroll-top"

    reachable = evaluate_script(<<~JS)
      (() => {
        const wrap = document.querySelector('.preview-card.active .contact-form-wrap')
        const box  = wrap.parentElement
        box.scrollTop = box.scrollHeight
        const note  = wrap.querySelector('.contact-note')
        const email = wrap.querySelector('.contact-field[data-contact-key="email"]')
        const boxR  = box.getBoundingClientRect()
        const fits  = (el) => {
          const r = el.getBoundingClientRect()
          return r.top >= boxR.top - 1 && r.bottom <= boxR.bottom + 1
        }
        return fits(note) && fits(email)
      })()
    JS
    assert reachable,
      "scrolled to the end, the email field and privacy note must both sit inside the scrollport"
  end
end
