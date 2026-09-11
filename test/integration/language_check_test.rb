require "test_helper"

# The Language check screen: every card's wording in every language the Verto
# has, and the owner-side links that hand that page to somebody without an
# account.
#
# The highest-stakes assertions here are the ones about what an edit DOES —
# a reviewer's fix has to land in the deck the player serves (that is the
# feature), without ever resizing an option list (that is the alignment every
# stored answer depends on) and without an older editor tab writing it back.
class LanguageCheckScreenTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(name: "Nick", email_address: "lc-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @org = Organisation.create!(name: "LC Org", slug: "lc-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(
      title: "Colours", theme: "Colours", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: %w[en es fr],
      cards: [
        { "type" => "welcome_card", "cid" => "c_w", "title" => "hi", "text" => "Welcome" },
        { "type" => "multiple_choice", "cid" => "c_mc", "text" => "Favourite colour?",
          "description" => "Pick one", "options" => %w[Blue Green],
          "i18n" => { "es" => { "text" => "¿Color favorito?", "options" => %w[Azul Verde] } } }
      ]
    )
  end

  def sign_in(user = @user)
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def mc_card
    @survey.reload.cards.find { |c| c["cid"] == "c_mc" }
  end

  # ── The screen ─────────────────────────────────────────────────────────────

  test "the screen shows every language's wording for a card, primary first" do
    sign_in
    get survey_language_check_path(@survey)
    assert_response :success

    assert_match "Favourite colour?", response.body, "the primary line must be shown"
    assert_match "¿Color favorito?", response.body, "the Spanish translation must be shown"
    # French has no i18n entry, so its line falls back to the primary wording —
    # which is exactly what the player renders for it. A blank line there would
    # have a reviewer approve something nobody will see.
    assert_match "language_check.untranslated_note", response.body.gsub(
      I18n.t("language_check.untranslated_note"), "language_check.untranslated_note"
    ), "an untranslated line must say so rather than passing English off as French"
  end

  test "a one-language Verto is told so instead of shown an empty board" do
    @survey.update!(locales: [ "en" ])
    sign_in
    get survey_language_check_path(@survey)
    assert_response :success
    assert_match I18n.t("language_check.single_language_title"), response.body
  end

  test "the editor links to the screen and carries its wording revision" do
    @survey.update!(translations_revision: 4)
    sign_in
    get survey_path(@survey)
    assert_response :success
    assert_match survey_language_check_path(@survey), response.body
    assert_match 'data-survey-editor-translations-revision-value="4"', response.body,
                 "the editor must send back the revision it was rendered at"
  end

  test "another organisation's Verto is not reachable" do
    other = User.create!(name: "Other", email_address: "o-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    other_org = Organisation.create!(name: "Other", slug: "o-#{SecureRandom.hex(3)}")
    other_org.memberships.create!(user: other, role: "admin")
    sign_in(other)
    get survey_language_check_path(@survey)
    assert_response :not_found
  end

  # ── Approving ──────────────────────────────────────────────────────────────

  test "approving a line records who, when, and the words approved" do
    sign_in
    post survey_language_check_lines_path(@survey), params: { cid: "c_mc", locale: "es", verb: "approve" }
    assert_response :redirect

    row = LanguageCheck.find_by!(survey: @survey, cid: "c_mc", locale: "es")
    assert_equal "approved", row.status
    assert_equal @user, row.reviewed_by_user
    assert row.content_digest.present?, "the approved wording must be fingerprinted"
    assert row.source_digest.present?,
           "a translation's approval must also record the primary wording it was checked against"
  end

  test "taking an approval back clears the record of it, not just the status" do
    sign_in
    post survey_language_check_lines_path(@survey), params: { cid: "c_mc", locale: "es", verb: "approve" }
    row = LanguageCheck.find_by!(survey: @survey, cid: "c_mc", locale: "es")
    assert_equal @user, row.reviewed_by_user

    post survey_language_check_lines_path(@survey), params: { cid: "c_mc", locale: "es", verb: "reset" }

    row.reload
    assert_equal "pending", row.status
    assert_nil row.reviewed_by_user
    assert_nil row.reviewed_at
    assert_nil row.content_digest,
               "a row still carrying the fingerprint of an approval nobody stands behind " \
               "would resurface as a stale badge the next time the text changed"
    assert_nil row.source_digest
  end

  test "editing a line after approval leaves the approval visibly stale" do
    sign_in
    post survey_language_check_lines_path(@survey), params: { cid: "c_mc", locale: "es", verb: "approve" }
    row = LanguageCheck.find_by!(survey: @survey, cid: "c_mc", locale: "es")

    post survey_language_check_lines_path(@survey),
         params: { cid: "c_mc", locale: "es", verb: "edit", fields: { text: "¿Cuál es tu color favorito?" } }

    card    = mc_card
    content = LanguageCheckLines.translated_content(card, "es", LanguageCheckLines.canonical_content(card))
    assert_equal "approved", row.reload.status,
                 "the row keeps the reviewer's decision — the screen reports it as stale, it is not erased"
    assert_equal "stale", LanguageCheck.state_for(row, LanguageCheckLines.digest(content)),
                 "wording edited after approval must read as stale"
  end

  test "rewriting the primary language lapses the translations approved against it" do
    sign_in
    post survey_language_check_lines_path(@survey), params: { cid: "c_mc", locale: "es", verb: "approve" }
    row = LanguageCheck.find_by!(survey: @survey, cid: "c_mc", locale: "es")

    # The Spanish has not changed — the English under it has. A translation
    # approval is a judgement about fidelity to a source, so it has to lapse.
    post survey_language_check_lines_path(@survey),
         params: { cid: "c_mc", locale: "en", verb: "edit", fields: { text: "Which colour do you like best?" } }

    card    = mc_card
    content = LanguageCheckLines.translated_content(card, "es", LanguageCheckLines.canonical_content(card))
    source  = LanguageCheckLines.digest(LanguageCheckLines.canonical_content(card))
    assert_equal "stale", LanguageCheck.state_for(row.reload, LanguageCheckLines.digest(content), source)
  end

  # ── Editing ────────────────────────────────────────────────────────────────

  test "an edit to a translation lands in the deck the player serves" do
    sign_in
    post survey_language_check_lines_path(@survey),
         params: { cid: "c_mc", locale: "es", verb: "edit",
                   fields: { text: "¿Cuál es tu color favorito?", options: [ "Azul", "Verde lima" ] } }

    entry = mc_card.dig("i18n", "es")
    assert_equal "¿Cuál es tu color favorito?", entry["text"]
    assert_equal [ "Azul", "Verde lima" ], entry["options"]
    assert_equal 1, @survey.reload.translations_revision
  end

  test "an edit never resizes an option list" do
    sign_in
    post survey_language_check_lines_path(@survey),
         params: { cid: "c_mc", locale: "es", verb: "edit",
                   fields: { options: [ "Azul", "Verde", "Rojo", "Amarillo" ] } }

    assert_equal 2, mc_card.dig("i18n", "es", "options").length,
                 "option N in every language is a label for option N — a translation " \
                 "that grows the list would shear every stored answer's alignment"
    assert_equal %w[Blue Green], mc_card["options"], "the canonical list is untouched"
  end

  test "a blank translation field clears the override rather than storing empty text" do
    sign_in
    post survey_language_check_lines_path(@survey),
         params: { cid: "c_mc", locale: "es", verb: "edit", fields: { text: "" } }

    entry = mc_card.dig("i18n", "es")
    assert_not entry.key?("text"),
               "blank means 'show the original here' — the player falls back to the primary language"
  end

  test "a live Verto's canonical option labels are not editable, its question still is" do
    @survey.update!(publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)
    @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed",
                              answers: { "1" => { "value" => "Blue" } })
    sign_in
    post survey_language_check_lines_path(@survey),
         params: { cid: "c_mc", locale: "en", verb: "edit",
                   fields: { text: "Favorite colour?", options: %w[Navy Emerald] } }

    assert_equal %w[Blue Green], mc_card["options"],
                 "canonical option labels are the answer key for answers already collected"
    assert_equal "Favorite colour?", mc_card["text"],
                 "the question text carries no keys — fixing a typo in a live question must work"
  end

  test "a secondary language stays editable on a live Verto" do
    @survey.update!(publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)
    @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed",
                              answers: { "1" => { "value" => "Blue" } })
    sign_in
    post survey_language_check_lines_path(@survey),
         params: { cid: "c_mc", locale: "es", verb: "edit", fields: { options: [ "Azul marino", "Esmeralda" ] } }

    assert_equal [ "Azul marino", "Esmeralda" ], mc_card.dig("i18n", "es", "options"),
                 "nothing is keyed by a translated label, so it is always safe to fix"
  end

  test "editing the primary text drops the rich-text twin that would outrank it" do
    # text_html is a presentation-only copy of the SAME words, and the player
    # renders it in preference to the plain text whenever the two agree
    # (ApplicationHelper#rich_card_text). Left behind, the respondent keeps
    # reading the old sentence in bold and the reviewer's fix never shows.
    @survey.update!(cards: @survey.cards.map do |c|
      c["cid"] == "c_mc" ? c.merge("text_html" => "<b>Favourite colour?</b>") : c
    end)
    sign_in
    post survey_language_check_lines_path(@survey),
         params: { cid: "c_mc", locale: "en", verb: "edit", fields: { text: "Which colour wins?" } }

    assert_equal "Which colour wins?", mc_card["text"]
    assert_nil mc_card["text_html"], "a twin holding the old words must not outlive them"
  end

  test "an unchanged primary field keeps its rich-text twin" do
    @survey.update!(cards: @survey.cards.map do |c|
      c["cid"] == "c_mc" ? c.merge("text_html" => "<b>Favourite colour?</b>") : c
    end)
    sign_in
    post survey_language_check_lines_path(@survey),
         params: { cid: "c_mc", locale: "en", verb: "edit",
                   fields: { text: "Favourite colour?", description: "Choose one" } }

    assert_equal "<b>Favourite colour?</b>", mc_card["text_html"],
                 "formatting the reviewer never touched must survive"
    assert_equal "Choose one", mc_card["description"]
  end

  test "editing one option's words drops only that option's twin" do
    @survey.update!(cards: @survey.cards.map do |c|
      c["cid"] == "c_mc" ? c.merge("options_html" => [ "<b>Blue</b>", "<i>Green</i>" ]) : c
    end)
    sign_in
    post survey_language_check_lines_path(@survey),
         params: { cid: "c_mc", locale: "en", verb: "edit", fields: { options: %w[Navy Green] } }

    assert_equal %w[Navy Green], mc_card["options"]
    assert_nil mc_card["options_html"][0]
    assert_equal "<i>Green</i>", mc_card["options_html"][1],
                 "only the slot whose words moved loses its formatting"
  end

  test "a scenario page edit drops that page's html twin and leaves the others" do
    @survey.update!(cards: @survey.cards + [ {
      "type" => "scenario", "cid" => "c_sc", "text" => "A story",
      "pages" => [ { "id" => "p1", "text" => "First", "html" => "<b>First</b>" },
                   { "id" => "p2", "text" => "Second", "html" => "<b>Second</b>" } ]
    } ])
    sign_in
    post survey_language_check_lines_path(@survey),
         params: { cid: "c_sc", locale: "en", verb: "edit",
                   fields: { pages: [ { id: "p1", text: "Opening" }, { id: "p2", text: "Second" } ] } }

    pages = @survey.reload.cards.find { |c| c["cid"] == "c_sc" }["pages"]
    assert_equal "Opening", pages[0]["text"]
    assert_nil pages[0]["html"]
    assert_equal "<b>Second</b>", pages[1]["html"]
  end

  test "a translation edit never writes a rich-text twin into a secondary language" do
    # Translations are plain by contract — sanitize_cards_images! strips any
    # *_html inside i18n, and the editor's store only ever seeds html for the
    # primary. Nothing here may reintroduce one.
    sign_in
    post survey_language_check_lines_path(@survey),
         params: { cid: "c_mc", locale: "es", verb: "edit",
                   fields: { text: "<b>¿Color?</b>", text_html: "<b>¿Color?</b>" } }

    entry = mc_card.dig("i18n", "es")
    assert_not entry.key?("text_html")
    assert_equal "<b>¿Color?</b>", entry["text"],
                 "stored as the plain string it is — escaped on render, never as markup"
  end

  test "a card or language the Verto does not have is refused without saying which" do
    sign_in
    post survey_language_check_lines_path(@survey), params: { cid: "c_ghost", locale: "es", verb: "approve" }
    assert_response :redirect
    assert_equal 0, LanguageCheck.where(survey: @survey, cid: "c_ghost").count

    post survey_language_check_lines_path(@survey), params: { cid: "c_mc", locale: "de", verb: "approve" }
    assert_equal 0, LanguageCheck.where(survey: @survey, locale: "de").count
  end

  # ── Comments ───────────────────────────────────────────────────────────────

  test "a comment is recorded against the line and shown on the screen" do
    sign_in
    post survey_language_check_lines_path(@survey),
         params: { cid: "c_mc", locale: "es", verb: "note", body: "“Verde” should be “Verde claro” here." }

    note = LanguageCheckNote.find_by!(survey: @survey, cid: "c_mc", locale: "es")
    assert_equal @user, note.author_user
    get survey_language_check_path(@survey)
    assert_match "Verde claro", response.body
  end

  test "a blank comment is not stored" do
    sign_in
    post survey_language_check_lines_path(@survey),
         params: { cid: "c_mc", locale: "es", verb: "note", body: "   " }
    assert_equal 0, LanguageCheckNote.where(survey: @survey).count
  end

  test "an over-long comment is truncated rather than rejected" do
    sign_in
    post survey_language_check_lines_path(@survey),
         params: { cid: "c_mc", locale: "es", verb: "note", body: "x" * (LanguageCheckNote::MAX_BODY + 500) }
    assert_equal LanguageCheckNote::MAX_BODY,
                 LanguageCheckNote.find_by!(survey: @survey, cid: "c_mc", locale: "es").body.length
  end

  # ── Review links ───────────────────────────────────────────────────────────

  test "an admin mints a scoped review link" do
    sign_in
    post survey_language_check_links_path(@survey),
         params: { name: "Marta — Spanish", locales: [ "es" ], can_edit: "1" }

    link = @survey.language_check_links.sole
    assert_equal "Marta — Spanish", link.name
    assert_equal [ "es" ], link.visible_locales
    assert link.can_edit?
    assert link.token.present?
  end

  test "a link scoped to no locales sees every language" do
    sign_in
    post survey_language_check_links_path(@survey), params: { name: "Everyone" }
    assert_equal %w[en es fr], @survey.language_check_links.sole.visible_locales
  end

  test "a link stops offering a language the Verto has dropped" do
    link = @survey.language_check_links.create!(locales: %w[es fr])
    @survey.update!(locales: %w[en es])
    assert_equal [ "es" ], link.visible_locales
  end

  test "pausing keeps the URL, revoking destroys it and keeps the review record" do
    sign_in
    link = @survey.language_check_links.create!(name: "Marta")
    @survey.language_checks.create!(cid: "c_mc", locale: "es", status: "approved",
                                    language_check_link: link, reviewed_by_name: "Marta")

    patch survey_language_check_link_path(@survey, link), params: { active: "0" }
    assert_not link.reload.active?

    delete survey_language_check_link_path(@survey, link)
    assert_not LanguageCheckLink.exists?(link.id)
    row = LanguageCheck.find_by!(survey: @survey, cid: "c_mc", locale: "es")
    assert_equal "approved", row.status,
                 "revoking a link must not reset a Verto's review state to 'nobody has looked at this'"
    assert_nil row.language_check_link_id
  end

  test "a non-admin can read the screen but not mint a link" do
    viewer = User.create!(name: "V", email_address: "v-#{SecureRandom.hex(3)}@test.com",
                          password: "verylongpassword")
    @org.memberships.create!(user: viewer, role: "viewer")
    sign_in(viewer)

    get survey_language_check_path(@survey)
    assert_response :success

    post survey_language_check_links_path(@survey), params: { name: "Nope" }
    assert_response :redirect
    assert_equal 0, @survey.language_check_links.count
  end

  test "a viewer seat rules on the wording but cannot rewrite it" do
    viewer = User.create!(name: "V", email_address: "v2-#{SecureRandom.hex(3)}@test.com",
                          password: "verylongpassword")
    @org.memberships.create!(user: viewer, role: "viewer")
    sign_in(viewer)

    # Reading the wording and saying whether it is right is what a viewer seat
    # is for, so approving and commenting are open to it.
    post survey_language_check_lines_path(@survey), params: { cid: "c_mc", locale: "es", verb: "approve" }
    assert LanguageCheck.exists?(survey: @survey, cid: "c_mc", locale: "es")
    post survey_language_check_lines_path(@survey),
         params: { cid: "c_mc", locale: "es", verb: "note", body: "Reads oddly." }
    assert LanguageCheckNote.exists?(survey: @survey, cid: "c_mc", locale: "es")

    # Rewriting the Verto is not. This screen is a write path into `cards` like
    # any other, and the same line applies.
    post survey_language_check_lines_path(@survey),
         params: { cid: "c_mc", locale: "es", verb: "edit", fields: { text: "Cambiado" } }
    assert_equal "¿Color favorito?", mc_card.dig("i18n", "es", "text")
    assert_equal 0, @survey.reload.translations_revision

    get survey_language_check_path(@survey)
    assert_no_match I18n.t("language_check.edit"), response.body,
                    "the page must not offer a button the endpoint would refuse"
  end

  test "the number of live review links is bounded" do
    sign_in
    LanguageCheckLinksController::MAX_PER_SURVEY.times { @survey.language_check_links.create! }
    post survey_language_check_links_path(@survey), params: { name: "One too many" }
    assert_equal LanguageCheckLinksController::MAX_PER_SURVEY, @survey.language_check_links.count
  end

  # ── The lost-update guard ──────────────────────────────────────────────────

  test "an editor tab older than a reviewer's edit does not write the old wording back" do
    sign_in
    # A reviewer fixes the Spanish.
    post survey_language_check_lines_path(@survey),
         params: { cid: "c_mc", locale: "es", verb: "edit", fields: { text: "¡El mejor color!" } }
    assert_equal 1, @survey.reload.translations_revision

    # An editor tab rendered BEFORE that (revision 0) autosaves the whole deck,
    # carrying the Spanish it was seeded with.
    patch survey_path(@survey), params: {
      title: "Colours",
      translations_revision: 0,
      cards: [
        { "type" => "welcome_card", "cid" => "c_w", "title" => "hi", "text" => "Welcome" },
        { "type" => "multiple_choice", "cid" => "c_mc", "text" => "Favourite colour?",
          "description" => "Pick one", "options" => %w[Blue Green],
          "i18n" => { "es" => { "text" => "¿Color favorito?", "options" => %w[Azul Verde] } } }
      ]
    }.to_json, headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :success

    assert_equal "¡El mejor color!", mc_card.dig("i18n", "es", "text"),
                 "the reviewer's wording must survive an autosave from a tab that never saw it"
  end

  test "an editor tab that has seen the edit is still authoritative about translations" do
    sign_in
    post survey_language_check_lines_path(@survey),
         params: { cid: "c_mc", locale: "es", verb: "edit", fields: { text: "¡El mejor color!" } }
    revision = @survey.reload.translations_revision

    patch survey_path(@survey), params: {
      title: "Colours",
      translations_revision: revision,
      cards: [
        { "type" => "welcome_card", "cid" => "c_w", "title" => "hi", "text" => "Welcome" },
        { "type" => "multiple_choice", "cid" => "c_mc", "text" => "Favourite colour?",
          "description" => "Pick one", "options" => %w[Blue Green],
          "i18n" => { "es" => { "text" => "Otro texto", "options" => %w[Azul Verde] } } }
      ]
    }.to_json, headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :success

    assert_equal "Otro texto", mc_card.dig("i18n", "es", "text"),
                 "a creator editing Spanish in an up-to-date editor must not be overruled"
  end

  test "an editor payload with no revision at all is treated as stale" do
    sign_in
    post survey_language_check_lines_path(@survey),
         params: { cid: "c_mc", locale: "es", verb: "edit", fields: { text: "¡El mejor color!" } }

    patch survey_path(@survey), params: {
      title: "Colours",
      cards: [
        { "type" => "welcome_card", "cid" => "c_w", "title" => "hi", "text" => "Welcome" },
        { "type" => "multiple_choice", "cid" => "c_mc", "text" => "Favourite colour?",
          "description" => "Pick one", "options" => %w[Blue Green],
          "i18n" => { "es" => { "text" => "¿Color favorito?", "options" => %w[Azul Verde] } } }
      ]
    }.to_json, headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :success

    assert_equal "¡El mejor color!", mc_card.dig("i18n", "es", "text"),
                 "a cached client from before this shipped must not silently lose a reviewer's fix"
  end

  test "the guard leaves the rest of the deck to the editor" do
    sign_in
    post survey_language_check_lines_path(@survey),
         params: { cid: "c_mc", locale: "es", verb: "edit", fields: { text: "¡El mejor color!" } }

    patch survey_path(@survey), params: {
      title: "Colours",
      translations_revision: 0,
      cards: [
        { "type" => "welcome_card", "cid" => "c_w", "title" => "hi", "text" => "Welcome" },
        { "type" => "multiple_choice", "cid" => "c_mc", "text" => "A brand new question?",
          "description" => "Pick one", "options" => %w[Blue Green],
          "i18n" => { "es" => { "text" => "¿Color favorito?", "options" => %w[Azul Verde] } } }
      ]
    }.to_json, headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :success

    assert_equal "A brand new question?", mc_card["text"],
                 "only the (card, language) pairs the reviewer touched are carried forward"
    assert_equal "¡El mejor color!", mc_card.dig("i18n", "es", "text")
  end
end
