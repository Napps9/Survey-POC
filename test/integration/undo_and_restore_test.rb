require "test_helper"

# Undo, in the two layers a creator actually needs:
#
#   in-session  — ⌘Z on structural card edits (JS; the server side is only that
#                 the resulting deck saves normally)
#   durable     — surviving a reload: a bin of recently deleted cards, and a way
#                 back from an archived Verto
#
# The archive half needed no new model work at all: deleted_at, archive! and the
# kept/archived scopes were already there. There was simply no way back.
class UndoAndRestoreTest < ActionDispatch::IntegrationTest
  CARDS = [
    { "type" => "welcome_card", "cid" => "c_w", "title" => "hi" },
    { "type" => "yes_no",     "cid" => "c_a", "text" => "Keep me?", "options" => %w[Yes No] },
    { "type" => "open_ended", "cid" => "c_b", "text" => "Why?" }
  ].freeze

  def setup
    @user = User.create!(name: "U", email_address: "undo-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "undo-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def draft(cards: CARDS)
    @org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                         default_locale: "en", locales: [ "en" ], cards: cards.map(&:dup))
  end

  def save_cards(s, cards)
    patch survey_path(s), params: { cards: cards }.to_json,
                          headers: { "CONTENT_TYPE" => "application/json" }
  end

  # ── The bin ───────────────────────────────────────────────────────────────

  test "a card that leaves the deck lands in the bin" do
    s = draft
    save_cards(s, CARDS.reject { |c| c["cid"] == "c_a" })
    assert_response :success

    bin = s.reload.recently_deleted_cards
    assert_equal 1, bin.size
    assert_equal "c_a", bin.first.dig("card", "cid")
    assert_equal "Keep me?", bin.first.dig("card", "text"), "the whole card, not a stub"
    assert bin.first["deleted_at"].present?
  end

  test "a reorder is not a deletion" do
    s = draft
    save_cards(s, [ CARDS[0], CARDS[2], CARDS[1] ])
    assert_empty s.reload.recently_deleted_cards,
                 "matched on cid, so moving a card can't read as removing one"
  end

  test "the bin is newest-first and bounded" do
    cards = (0...(Survey::MAX_DELETED_CARDS + 4)).map { |i| { "type" => "open_ended", "cid" => "c_#{i}", "text" => "Q#{i}" } }
    s = draft(cards: cards)

    # Delete them one at a time, oldest first.
    cards.each_with_index { |_c, i| save_cards(s, cards[(i + 1)..]) }

    bin = s.reload.recently_deleted_cards
    assert_equal Survey::MAX_DELETED_CARDS, bin.size
    assert_equal "c_#{cards.size - 1}", bin.first.dig("card", "cid"), "newest first"
  end

  test "restoring a card takes it back out of the bin" do
    s = draft
    save_cards(s, CARDS.reject { |c| c["cid"] == "c_a" })
    assert_equal 1, s.reload.recently_deleted_cards.size

    save_cards(s, CARDS)
    assert_empty s.reload.recently_deleted_cards,
                 "a card that's back in the deck can't also be in the bin"
  end

  test "several cards removed at once all land in the bin" do
    s = draft
    save_cards(s, [ CARDS[0] ])
    assert_equal %w[c_a c_b].sort, s.reload.recently_deleted_cards.map { |e| e.dig("card", "cid") }.sort
  end

  # ── Restoring across a reload ─────────────────────────────────────────────

  test "restore_card renders the card, keeping its original cid" do
    s = draft
    save_cards(s, CARDS.reject { |c| c["cid"] == "c_a" })

    post restore_survey_card_path(s), params: { cid: "c_a" }.to_json,
                                      headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :success
    body = JSON.parse(response.body)
    assert body["ok"]
    assert_equal "c_a", body["cid"], "the original cid, so routes pointing at it resolve again"
    assert_match "Keep me?", body["html"]
    assert_match "c_a", body["html"]
  end

  test "restore_card leaves the bin alone — the save is what empties it" do
    s = draft
    save_cards(s, CARDS.reject { |c| c["cid"] == "c_a" })
    post restore_survey_card_path(s), params: { cid: "c_a" }.to_json,
                                      headers: { "CONTENT_TYPE" => "application/json" }

    assert_equal 1, s.reload.recently_deleted_cards.size,
                 "rendering isn't restoring; only a deck containing the card is"
  end

  test "an unknown cid is a 404, not a crash" do
    s = draft
    post restore_survey_card_path(s), params: { cid: "c_nope" }.to_json,
                                      headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :not_found
  end

  test "a locked Verto refuses to restore a card" do
    s = draft
    save_cards(s, CARDS.reject { |c| c["cid"] == "c_a" })
    s.update!(publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)

    post restore_survey_card_path(s), params: { cid: "c_a" }.to_json,
                                      headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :locked
  end

  test "the editor lists recently deleted cards, and hides the list when empty" do
    s = draft
    get survey_path(s)
    assert_select "[data-controller='deleted-cards']", false, "nothing deleted yet"

    save_cards(s, CARDS.reject { |c| c["cid"] == "c_a" })
    get survey_path(s)
    assert_select "[data-controller='deleted-cards']"
    assert_select "[data-restore-cid='c_a']"
  end

  test "a live Verto is not offered the list at all" do
    s = draft
    save_cards(s, CARDS.reject { |c| c["cid"] == "c_a" })
    s.update!(publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)

    get survey_path(s)
    assert_select "[data-controller='deleted-cards']", false
  end

  # ── Restoring a whole Verto ───────────────────────────────────────────────

  test "an archived Verto can be restored, and comes back as a draft" do
    s = draft
    s.update!(publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)
    delete survey_path(s)
    assert s.reload.deleted?

    post restore_survey_path(s)
    assert_redirected_to root_path
    s.reload

    assert_not s.deleted?
    assert_not s.published?, "the old /play link must not quietly go live again"
    assert s.publish_token.present?, "but the link is kept, so re-publishing restores it"
  end

  test "restoring a never-published Verto leaves it a plain draft" do
    s = draft
    delete survey_path(s)
    post restore_survey_path(s)
    s.reload

    assert_not s.deleted?
    assert_nil s.unpublished_at, "nothing to un-publish, so nothing is stamped"
  end

  test "the archived tile offers Restore" do
    s = draft
    delete survey_path(s)

    get root_path
    assert_response :success
    assert_select "form[action=?]", restore_survey_path(s)
  end

  test "restore is admin-only" do
    s = draft
    delete survey_path(s)

    member = User.create!(name: "M", email_address: "m-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @org.memberships.create!(user: member, role: "member")
    post session_path, params: { email_address: member.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?

    post restore_survey_path(s)
    assert s.reload.deleted?, "still archived"
  end

  test "another organisation cannot restore your Verto" do
    s = draft
    delete survey_path(s)

    other = User.create!(name: "X", email_address: "x-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    other_org = Organisation.create!(name: "X", slug: "x-#{SecureRandom.hex(3)}")
    other_org.memberships.create!(user: other, role: "admin")
    post session_path, params: { email_address: other.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?

    post restore_survey_path(s)
    assert_response :not_found
    assert s.reload.deleted?
  end
end
