require "test_helper"

# The intro modal on a LOCKED deck — a Verto that is live, or has collected an
# answer, and so refuses every other content edit.
#
# editing_locked? exists because answers are stored against card POSITION, and
# a deck change re-points every answer already collected. A modal is a per-card
# field: it moves no card, adds and removes none, and is not an answer, so the
# reasoning does not reach it. These are the tests that keep that claim true —
# the endpoint is only safe outside the lock for as long as it remains
# incapable of reshaping a deck.
class CardModalLockedTest < ActionDispatch::IntegrationTest
  CARDS = [
    { "type" => "welcome_card", "cid" => "w1", "title" => "Hello" },
    { "type" => "yes_no", "cid" => "q1", "text" => "Do you feel safe here?", "options" => %w[Yes No] },
    { "type" => "select_many", "cid" => "q2", "text" => "Which have you used?",
      "options" => [ "A food bank", "A debt adviser" ] }
  ].freeze

  def setup
    @user = User.create!(name: "U", email_address: "cml-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "cml-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                                   default_locale: "en", locales: [ "en" ], cards: CARDS.map(&:dup),
                                   publish_token: SecureRandom.urlsafe_base64(18),
                                   published_at: Time.current)
    sign_in!
  end

  def sign_in!
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def card(cid) = @survey.reload.cards.find { |c| c["cid"] == cid }

  test "the deck really is locked — this is the precondition everything else rests on" do
    assert @survey.editing_locked?, "a published Verto must be locked"

    patch survey_path(@survey), params: { cards: CARDS.map(&:dup) }, as: :json
    assert_response :locked, "the ordinary autosave must still be refused"
  end

  test "a locked deck can gain a modal" do
    patch card_modal_survey_path(@survey), params: {
      cid: "q2", modal_title: "Before you answer", modal_body: "We mean the last year."
    }, as: :json

    assert_response :success
    assert_equal "Before you answer", card("q2")["modal_title"]
    assert_equal "We mean the last year.", card("q2")["modal_body"]
  end

  test "…and reword it, and lose it again" do
    patch card_modal_survey_path(@survey), params: {
      cid: "q2", modal_title: "First go", modal_body: "Body."
    }, as: :json
    patch card_modal_survey_path(@survey), params: {
      cid: "q2", modal_title: "Second go", modal_body: "Better body."
    }, as: :json
    assert_equal "Second go", card("q2")["modal_title"]

    patch card_modal_survey_path(@survey), params: {
      cid: "q2", modal_title: "", modal_body: ""
    }, as: :json
    refute card("q2").key?("modal_title"), "blank words mean no modal, here as everywhere"
    refute card("q2").key?("modal_body")
  end

  # THE test. The endpoint sits outside the lock, so what stops it being a hole
  # is that it cannot express a structural change — not a promise that it won't.
  test "it touches nothing but the named card's modal" do
    before = @survey.cards.deep_dup

    patch card_modal_survey_path(@survey), params: {
      cid: "q2", modal_title: "Heads up", modal_body: "Words.",
      # Everything a hostile or confused client might hope to smuggle through.
      cards: [], text: "Rewritten question", options: %w[X Y], type: "open_ended",
      title: "Renamed Verto", published_at: nil
    }, as: :json
    assert_response :success

    after = @survey.reload.cards
    assert_equal before.length, after.length, "no card was added or removed"
    assert_equal before.map { |c| c["cid"] }, after.map { |c| c["cid"] }, "no card moved"
    assert_equal "T", @survey.title, "a Verto attribute outside the deck is untouched"
    assert @survey.published?, "and so is its published state"

    before.zip(after).each do |was, now|
      if was["cid"] == "q2"
        assert_equal "Heads up", now["modal_title"]
        assert_equal was.except("modal_title", "modal_body"), now.except("modal_title", "modal_body"),
                     "the target card kept every field but its modal"
      else
        assert_equal was, now, "card #{was['cid']} was not the target and must be byte-identical"
      end
    end
  end

  test "the card is addressed by cid, never by position" do
    patch card_modal_survey_path(@survey), params: {
      cid: "nope", modal_title: "T", modal_body: "B"
    }, as: :json

    assert_response :not_found
    assert_equal CARDS.map { |c| c["cid"] }, @survey.reload.cards.map { |c| c["cid"] }
    refute @survey.cards.any? { |c| c["modal_title"] }, "an unmatched cid writes nothing at all"
  end

  test "a blank cid is refused rather than matching the first cid-less card" do
    patch card_modal_survey_path(@survey), params: { cid: "", modal_title: "T", modal_body: "B" },
          as: :json

    assert_response :not_found
  end

  test "the same bounds apply as on the unlocked path" do
    patch card_modal_survey_path(@survey), params: {
      cid: "q1", modal_title: "t" * 500, modal_body: "b" * 5_000,
      modal_body_html: "<script>alert(1)</script>"
    }, as: :json

    assert_response :success
    assert_equal Survey::MAX_MODAL_TITLE, card("q1")["modal_title"].length
    assert_equal Survey::MAX_MODAL_BODY, card("q1")["modal_body"].length
    refute card("q1")["modal_body_html"].to_s.include?("script"),
           "html that does not read as its plain twin is dropped, lock or no lock"
  end

  # Skipping editing_locked? must not be mistaken for skipping permission. The
  # lock asks whether this DECK is frozen; the editing gate asks whether this
  # MEMBER may edit at all. A viewer never may, live deck or draft.
  test "a viewer cannot write a modal, locked deck or not" do
    viewer = User.create!(name: "V", email_address: "vw-#{SecureRandom.hex(3)}@test.com",
                          password: "verylongpassword")
    @org.memberships.create!(user: viewer, role: "viewer")

    delete session_path rescue nil
    post session_path, params: { email_address: viewer.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?

    patch card_modal_survey_path(@survey), params: {
      cid: "q1", modal_title: "Sneaked in", modal_body: "Not allowed."
    }, as: :json

    refute_equal "Sneaked in", card("q1")["modal_title"]
    refute card("q1").key?("modal_title"), "a viewer's write must not land"
  end

  test "another organisation's Verto is not reachable, lock or no lock" do
    other_user = User.create!(name: "X", email_address: "oth-#{SecureRandom.hex(3)}@test.com",
                              password: "verylongpassword")
    other_org  = Organisation.create!(name: "X", slug: "oth-#{SecureRandom.hex(3)}")
    other_org.memberships.create!(user: other_user, role: "admin")
    theirs = other_org.surveys.create!(title: "Theirs", theme: "T", audience_age: "all",
                                       key_insight: "x", default_locale: "en", locales: [ "en" ],
                                       cards: CARDS.map(&:dup))

    patch card_modal_survey_path(theirs), params: { cid: "q1", modal_title: "T", modal_body: "B" },
          as: :json

    assert_response :not_found, "the lookup is organisation-scoped, so it never finds their Verto"
    refute theirs.reload.cards.any? { |c| c["modal_title"] },
           "and writes nothing to it"
  end

  test "a respondent meets the modal a locked deck just gained" do
    patch card_modal_survey_path(@survey), params: {
      cid: "q2", modal_title: "Before you answer", modal_body: "We mean the last year."
    }, as: :json

    delete session_path rescue nil
    get play_survey_path(@survey.publish_token)

    assert_response :success
    assert_select "[data-card-cid='q2'][data-card-modal='true']", 1
    assert_match "We mean the last year.", response.body
  end

  # cids are minted by the cards sanitiser, and the only caller is the editor's
  # own autosave — so a Verto generated, imported or seeded and published
  # WITHOUT ever being edited has none, and once locked it never would. Since
  # the modal addresses a card by cid (that is what makes it unable to move
  # one), those decks could not use the one edit they are allowed.
  test "opening the editor gives a cid-less deck its cids" do
    @survey.update_columns(cards: @survey.cards.map { |c| c.except("cid") })
    assert @survey.reload.cards.none? { |c| c["cid"].present? }, "precondition"

    get survey_path(@survey)
    assert_response :success

    cards = @survey.reload.cards
    assert cards.all? { |c| c["cid"].present? }, "every card can now be named"
    assert_equal cards.map { |c| c["cid"] }.uniq.length, cards.length, "and named uniquely"
    assert_equal CARDS.length, cards.length, "minting an id moves no card"
    assert_equal CARDS.map { |c| c["text"] }, cards.map { |c| c["text"] }, "and reorders none"
  end

  test "the backfill is a no-op once a deck has its cids" do
    get survey_path(@survey)
    first = @survey.reload.cards.map { |c| c["cid"] }

    get survey_path(@survey)
    assert_equal first, @survey.reload.cards.map { |c| c["cid"] },
                 "a second open must not re-mint ids that answers and routes point at"
  end

  test "the lock bar says what a locked deck can still take" do
    get survey_path(@survey)

    assert_response :success
    # The apostrophe in the copy renders escaped, so match the clause that
    # carries the meaning rather than the whole string.
    assert_match "it explains a question without changing it", response.body,
                 "a bar that lists only what is refused leaves the one available fix invisible"
  end
end
