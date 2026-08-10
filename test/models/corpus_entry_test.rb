require "test_helper"

# The Ask Verto consent gate.
#
# This is the test the whole feature rests on: a Verto's data may cross an
# organisation boundary only when BOTH its creator has offered it (and not taken
# that back) AND VertoNow has approved it. Everything else in Ask Verto reads
# through CorpusEntry.citable, so if this file is green the product cannot answer
# from data it wasn't given.
#
# The combination test below is deliberately exhaustive rather than illustrative.
# There are only twelve states and the cost of missing one is a data leak, so all
# twelve are enumerated and each is asserted against BOTH the scope and the
# predicate — the two must never be allowed to drift apart.
class CorpusEntryTest < ActiveSupport::TestCase
  def setup
    @org  = Organisation.create!(name: "O", slug: "ce-#{SecureRandom.hex(3)}")
    @user = User.create!(email_address: "ce-#{SecureRandom.hex(3)}@example.com",
                         name: "Creator", password: "correct-horse-battery")
  end

  def survey(title = "S")
    @org.surveys.create!(title: title, theme: "T", audience_age: "all", key_insight: "x",
                         default_locale: "en", locales: [ "en" ], cards: [])
  end

  def entry(opted_in:, withdrawn:, review_status:)
    e = CorpusEntry.create!(survey: survey, organisation: @org, review_status: review_status)
    e.update!(opted_in_at: 2.days.ago, opted_in_by: @user) if opted_in
    e.update!(withdrawn_at: 1.day.ago) if withdrawn
    e.reload
  end

  # ── The whole truth table ─────────────────────────────────────────────────
  test "citable exactly when opted in, not withdrawn, and approved" do
    expectations = {
      # [opted_in, withdrawn, review_status] => citable?
      [ false, false, "pending" ]  => false,
      [ false, false, "approved" ] => false,   # approved but never offered
      [ false, false, "declined" ] => false,
      [ true,  false, "pending" ]  => false,   # offered, waiting on us
      [ true,  false, "approved" ] => true,    # the ONLY citable state
      [ true,  false, "declined" ] => false,
      [ true,  true,  "pending" ]  => false,
      [ true,  true,  "approved" ] => false,   # withdrawn beats our approval
      [ true,  true,  "declined" ] => false,
      [ false, true,  "pending" ]  => false,
      [ false, true,  "approved" ] => false,
      [ false, true,  "declined" ] => false
    }

    expectations.each do |(opted_in, withdrawn, status), expected|
      e = entry(opted_in: opted_in, withdrawn: withdrawn, review_status: status)
      label = "opted_in=#{opted_in} withdrawn=#{withdrawn} review=#{status}"

      assert_equal expected, e.citable?, "#citable? wrong for #{label}"
      assert_equal expected, CorpusEntry.citable.exists?(e.id), "scope wrong for #{label}"
    end
  end

  test "withdrawal takes a live Verto out of the corpus immediately" do
    e = entry(opted_in: true, withdrawn: false, review_status: "approved")
    assert e.citable?

    e.withdraw!

    assert_not e.citable?
    assert_not CorpusEntry.citable.exists?(e.id)
    # The index is NOT required to have been rebuilt — withdrawal is a read-time
    # filter, so there must be no window where the rows still answer.
    assert_equal "approved", e.review_status, "withdrawal should not rewrite our decision"
  end

  test "a declined Verto keeps the creator's opt-in" do
    e = entry(opted_in: true, withdrawn: false, review_status: "pending")
    e.decline!("staff@vertonow.com", "Fewer than 30 responses with answers.")

    assert_equal "declined", e.review_status
    assert e.opted_in?, "the creator said yes; a decline must not make them say it again"
    assert_equal :declined, e.creator_state
    assert_equal "Fewer than 30 responses with answers.", e.review_note
  end

  test "a reviewer passed as a User is recorded by their address" do
    e = entry(opted_in: true, withdrawn: false, review_status: "pending")
    e.approve!(@user)

    assert_equal @user.email_address, e.reviewed_by_email,
      'ActiveRecord would happily cast a User with to_s, and "#<User:0x…>" names nobody'
  end

  test "a reviewer that is neither an address nor a user is refused" do
    e = entry(opted_in: true, withdrawn: false, review_status: "pending")

    assert_raises(ArgumentError) { e.approve!(Object.new) }
    assert_equal "pending", e.reload.review_status
  end

  test "declining without a reason still stores something the creator can read" do
    e = entry(opted_in: true, withdrawn: false, review_status: "pending")
    e.decline!("staff@vertonow.com", "   ")

    assert_equal "No reason given.", e.review_note
  end

  test "re-offering after a withdrawal sends it back for review" do
    e = entry(opted_in: true, withdrawn: false, review_status: "approved")
    e.withdraw!

    e.opt_in!(@user)

    assert e.opted_in?
    assert_nil e.withdrawn_at
    assert_equal "pending", e.review_status,
      "our approval was granted against a consent that was revoked; it must not carry over"
    assert_not e.citable?
  end

  test "opting in again without a withdrawal does not reset an approval" do
    e = entry(opted_in: true, withdrawn: false, review_status: "approved")
    original = e.opted_in_at

    e.opt_in!(@user)

    assert_equal "approved", e.review_status
    assert_in_delta original.to_f, e.opted_in_at.to_f, 0.001, "a no-op opt-in must not re-date consent"
    assert e.citable?
  end

  test "approving clears a previous decline note" do
    e = entry(opted_in: true, withdrawn: false, review_status: "pending")
    e.decline!("staff@vertonow.com", "Too few responses.")
    e.approve!("staff@vertonow.com")

    assert e.citable?
    assert_nil e.review_note
    assert_equal "staff@vertonow.com", e.reviewed_by_email
  end

  test "creator_state names each state the editor panel renders" do
    assert_equal :off, entry(opted_in: false, withdrawn: false, review_status: "pending").creator_state
    assert_equal :pending, entry(opted_in: true, withdrawn: false, review_status: "pending").creator_state
    assert_equal :live, entry(opted_in: true, withdrawn: false, review_status: "approved").creator_state
    assert_equal :declined, entry(opted_in: true, withdrawn: false, review_status: "declined").creator_state
    assert_equal :off, entry(opted_in: true, withdrawn: true, review_status: "approved").creator_state
  end

  test "awaiting_review holds only offers waiting on us, oldest first" do
    old = entry(opted_in: true, withdrawn: false, review_status: "pending")
    old.update!(opted_in_at: 10.days.ago)
    recent = entry(opted_in: true, withdrawn: false, review_status: "pending")
    entry(opted_in: true, withdrawn: false, review_status: "approved")
    entry(opted_in: false, withdrawn: false, review_status: "pending")
    entry(opted_in: true, withdrawn: true, review_status: "pending")

    assert_equal [ old.id, recent.id ], CorpusEntry.awaiting_review.pluck(:id)
  end

  test "review_status is constrained in the database, not just the model" do
    e = entry(opted_in: true, withdrawn: false, review_status: "pending")

    assert_raises(ActiveRecord::StatementInvalid) do
      e.update_columns(review_status: "sort_of")
    end
  end

  test "for() builds an unsaved entry rather than enrolling a Verto by looking at it" do
    s = survey
    built = CorpusEntry.for(s)

    assert_not built.persisted?, "rendering the editor panel must not create a corpus row"
    assert_equal s.id, built.survey_id
    assert_equal @org.id, built.organisation_id
    assert_equal :off, built.creator_state
  end

  test "one entry per survey" do
    s = survey
    CorpusEntry.create!(survey: s, organisation: @org)

    assert_raises(ActiveRecord::RecordNotUnique) do
      CorpusEntry.create!(survey: s, organisation: @org)
    end
  end
end
