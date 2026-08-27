require "application_system_test_case"

# Reopening an answered Ask Verto conversation.
#
# The unit tests cover both halves separately — AskHelper renders the stored
# markers, and the Stimulus controller is handed a source list — but nothing
# covered the join, and that is exactly where the bug was: the controller used
# to rebuild its source map by scraping the citation chips, which carry an
# accent and nothing else. Every restored source card therefore showed a
# fallback glyph and "n 0", and no assertion anywhere noticed. It took opening
# the page in a browser.
#
# So this test asserts what only a browser can:
#   * a reloaded page hydrates real sources — right glyph, right count;
#   * clicking a chip opens the folder onto that source;
#   * two question types produce visibly different colours, computed, not just
#     declared on the element;
#   * a withdrawn Verto's words stop appearing in an answer already given.
class AskVertoReplayTest < ApplicationSystemTestCase
  def setup
    super
    @org  = Organisation.create!(name: "Anglo American Foundation", slug: "avr-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "Avr", email_address: "avr-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")

    @survey = @org.surveys.create!(
      title: "Valparaíso Youth Pulse", theme: "Climate Action", audience_age: "adults",
      key_insight: "k", default_locale: "en", locales: [ "en" ],
      brand_palette: { "primary" => "#FF8800", "cta" => "#FF8800", "bg" => "#1C2034", "panel" => "#2E3564" },
      cards: []
    )

    @entry = CorpusEntry.create!(survey: @survey, organisation: @org,
                                 review_status: "approved", opted_in_at: 1.day.ago,
                                 response_count: 2648)

    @choice = @entry.corpus_questions.create!(
      cid: "c_worry", position: 0, card_type: "multiple_choice", theme: "Climate Action",
      question_text: "How worried are you about climate change?",
      response_count: 2648, distribution: { "Very worried" => 864, "Somewhat worried" => 1275 }
    )
    @open = @entry.corpus_questions.create!(
      cid: "c_dream", position: 1, card_type: "open_ended", theme: "Climate Action",
      question_text: "What do you dream about for the future?",
      response_count: 2041, distribution: { "responses" => 2041 }
    )
    @quote = @open.corpus_quotes.create!(
      body: "Que la gente deje de pensar que no sirve de nada lo que hace una sola persona.",
      theme: "collective agency"
    )

    @thread = @org.ask_threads.create!(user: @user, title: "Climate worry")
    @thread.ask_messages.create!(role: "user", text: "Are young people worried?")
    @thread.ask_messages.create!(
      role: "assistant",
      text: "Worry is high [[c:1]]. In their own words [[c:2]]:\n[[q:#{@quote.id}]]",
      citations: [ citation_for(1, @choice), citation_for(2, @open) ]
    )
  end

  def citation_for(number, question)
    {
      "n" => number, "corpus_question_id" => question.id,
      "question" => question.question_text, "card_type" => question.card_type,
      "verto" => @survey.title, "organisation" => @org.name,
      "responses" => question.response_count, "fielded" => "Nov 2025",
      "theme" => question.theme,
      "accent" => CardTypes.accent(question.card_type),
      "icon" => CardTypes.icon(question.card_type),
      "brand" => @survey.brand_palette["primary"]
    }
  end

  def open_ask
    sign_in_as(@user)
    visit ask_path(thread_id: @thread.id)
    dismiss_cookie_banner
    assert_text "Worry is high"
  end

  # The regression this file exists for.
  test "a reloaded answer restores real sources, not fallback glyphs and zeroes" do
    open_ask

    # The folder is closed until it's asked for.
    assert_no_selector ".ask-grid.is-panel-open"
    find(".ask-fab-sources").click
    assert_selector ".ask-grid.is-panel-open"

    assert_selector ".ask-src", count: 2

    icons = all(".ask-src-icon").map(&:text)
    assert_equal [ CardTypes.icon("multiple_choice"), CardTypes.icon("open_ended") ], icons,
      "a scraped chip carries no glyph, so this is what regressed to ◆"

    metas = all(".ask-src-meta").map(&:text)
    assert(metas.none? { |m| m.include?("n 0") },
      "response counts must come from the stored citation, not default to zero")
    assert_match(/2[,.\s]?648/, metas.first)
    assert(metas.any? { |m| m.include?("Nov 2025") }, "the fielding window survives a reload too")
  end

  # Colour is load-bearing here: it tells a reader what kind of evidence each
  # citation points at. Asserting the inline property would only prove the
  # server wrote it — this proves the page actually paints two different colours.
  test "citations of different question types are visibly different colours" do
    open_ask

    chips = all(".ask-cite")
    assert_equal 2, chips.size

    painted = chips.map { |chip| chip.evaluate_script("getComputedStyle(this).borderColor") }
    assert_not_equal painted.first, painted.last,
      "a pick-one and an open-text citation must not look alike"
    assert(painted.none?(&:blank?))

    # And the source cards carry the Verto's own brand colour, which is a
    # different signal from the type accent. They only exist once the folder is
    # open, so ask for it first.
    find(".ask-fab-sources").click
    assert_selector ".ask-src", minimum: 1

    brand = find(".ask-src", match: :first).evaluate_script(
      "getComputedStyle(this).getPropertyValue('--verto-brand').trim()"
    )
    assert_equal "#FF8800", brand
  end

  test "clicking a citation opens the folder onto that source" do
    open_ask

    all(".ask-cite").last.click

    assert_selector ".ask-grid.is-panel-open"
    assert_selector ".ask-paper[data-pane='detail'].is-active"
    within ".ask-paper[data-pane='detail']" do
      # The question heading is uppercased by CSS (.ask-lab), so match the words
      # rather than the casing the stylesheet happens to apply.
      assert_text(/#{Regexp.escape(@open.question_text)}/i)
      assert_text @org.name
    end
    # And the tab strip agrees with the pane that is showing.
    assert_selector ".ask-tab[data-pane='detail'].is-active"
  end

  test "the consent tab explains why the source may be cited at all" do
    open_ask
    all(".ask-cite").first.click

    # This is the only test here that clicks something *inside* the folder
    # straight after opening it, and the folder arrives before it has stopped
    # moving: .ask-panel turns visible the instant is-panel-open lands
    # (transition-delay: 0s) while the grid column is still animating 0 → 468px
    # over 0.28s. Capybara will therefore happily click a consent tab that is
    # at x=1406 in a 1280px viewport — the click lands on nothing, _showPane
    # never runs, and the pane stays display:none. Wait for the pane the chip
    # selects, then for the slide, the same as the floating-chrome test below.
    assert_selector ".ask-paper[data-pane='detail'].is-active"
    sleep 0.4 # the 0.28s column slide, settled

    find(".ask-tab[data-pane='consent']").click
    assert_selector ".ask-tab[data-pane='consent'].is-active"

    within ".ask-paper[data-pane='consent']" do
      assert_text I18n.t("js.ask.consent_opted_in")
      assert_text I18n.t("js.ask.consent_approved")
      assert_text I18n.t("js.ask.consent_sample")
    end
  end

  test "a quote is printed from the stored record" do
    open_ask

    within ".ask-quote" do
      assert_text "Que la gente deje de pensar"
      # The theme label is uppercased by CSS, so match the words not the casing.
      assert_text(/collective agency/i)
    end
  end

  # The promise the creator was given, checked through the real render rather
  # than through the helper in isolation.
  test "withdrawing a Verto removes its words from an answer already given" do
    open_ask
    assert_selector ".ask-quote"

    @entry.withdraw!
    visit ask_path(thread_id: @thread.id)

    assert_text "Worry is high", wait: 5
    # Withdrawal must stop the words being shown, not only stop new answers
    # using them — the answer itself stays, its quote does not.
    assert_no_selector ".ask-quote"
    assert_no_text "Que la gente deje de pensar"
  end

  # The cold start is the other half of this screen, and it is generated from
  # the corpus — so it is worth proving it renders something real rather than a
  # placeholder.
  test "a thread with no messages shows the hero and its derived suggestions" do
    empty = @org.ask_threads.create!(user: @user, title: "New")

    sign_in_as(@user)
    visit ask_path(thread_id: empty.id)
    dismiss_cookie_banner

    assert_selector ".ask-hero"
    assert_selector ".ask-hero-stat", count: 3
    assert_selector ".ask-suggest", minimum: 1

    # Each chip carries an accent, and clicking one asks that exact question.
    accent = find(".ask-suggest", match: :first)[:style]
    assert_match(/--tile-accent:\s*#[0-9A-Fa-f]{6}/, accent.to_s)
  end

  test "an empty corpus says so rather than offering questions it cannot answer" do
    @entry.withdraw!
    empty = @org.ask_threads.create!(user: @user, title: "New")

    sign_in_as(@user)
    visit ask_path(thread_id: empty.id)
    dismiss_cookie_banner

    assert_selector ".ask-hero"
    assert_no_selector ".ask-suggest"
    assert_text I18n.t("js.ask.empty_corpus").first(40)
  end

  # The floating chrome is anchored to the grid, not the conversation column,
  # so a folder sliding out must not push a pill (2026-08-12: the back pill
  # used to travel right when the scope/threads folder opened). Only a browser
  # can see where a pill actually lands, so this is asserted here.
  test "the floating chrome holds its corners while the folders slide" do
    empty = @org.ask_threads.create!(user: @user, title: "New")

    sign_in_as(@user)
    visit ask_path(thread_id: empty.id)
    dismiss_cookie_banner

    back_pill = "document.querySelector('a.editor-leave-btn').getBoundingClientRect().left"
    # The CLUSTER's edge, not a pill inside it — the Sources fab hides while
    # the folder is out (by design), so the pills reflow within the cluster;
    # what must never move is where the cluster itself is anchored.
    pinned = "document.querySelector('.ask-float-pinned').getBoundingClientRect().right"

    back_before   = evaluate_script(back_pill)
    pinned_before = evaluate_script(pinned)

    find(".ask-rail-handle").click
    assert_selector ".ask-grid.is-rail-open"
    sleep 0.4 # the 0.28s column slide, settled
    assert_equal back_before, evaluate_script(back_pill),
      "the back pill must hold the top-left corner while the threads folder is out"

    find(".ask-fab-sources").click
    assert_selector ".ask-grid.is-panel-open"
    sleep 0.4
    assert_equal pinned_before, evaluate_script(pinned),
      "the pinned cluster must hold the top-right corner while the sources folder is out"
  end

  test "a long conversation scrolls inside the feed" do
    # Enough stored turns to overflow any viewport. The regression: the grid's
    # implicit row grew with the conversation instead of pinning to the grid's
    # height, so the feed's overflow-y never engaged and the tail of an answer
    # was simply clipped — nothing scrolled anywhere.
    6.times do |i|
      @thread.ask_messages.create!(role: "user", text: "Question #{i}?")
      @thread.ask_messages.create!(role: "assistant", text: "Answer #{i}. #{"A long paragraph of findings. " * 60}")
    end
    open_ask

    assert evaluate_script("document.querySelector('.ask-feed').scrollHeight > document.querySelector('.ask-feed').clientHeight"),
      "the conversation must overflow the feed, not grow it"

    execute_script("document.querySelector('.ask-feed').scrollTop = 99999")
    assert evaluate_script("document.querySelector('.ask-feed').scrollTop").positive?,
      "the feed must actually scroll — scrollTop pinned at 0 means the row grew instead"
  end

  test "an answer can be read aloud and stopped" do
    open_ask

    # The real speechSynthesis fires onend/onerror on its own schedule (and a
    # voiceless CI Chromium errors immediately), so the browser's engine is
    # stubbed out and what's asserted is our wiring: the toggle, the state
    # class, and the label swap.
    execute_script("window.speechSynthesis.speak = () => {}; window.speechSynthesis.cancel = () => {};")

    button = find(".ask-listen", match: :first)
    assert_equal I18n.t("js.ask.listen"), button["aria-label"]

    button.click
    assert_selector ".ask-listen.is-speaking"
    assert_equal I18n.t("js.ask.listen_stop"), find(".ask-listen.is-speaking")["aria-label"]

    find(".ask-listen.is-speaking").click
    assert_no_selector ".ask-listen.is-speaking"
    assert_equal I18n.t("js.ask.listen"), find(".ask-listen", match: :first)["aria-label"]
  end
end
