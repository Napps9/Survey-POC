require "test_helper"

# What makes an approval on the Language check screen mean something: it is an
# approval of particular words, and it lapses when those words — or the words
# above them — move.
class LanguageCheckTest < ActiveSupport::TestCase
  def setup
    @org = Organisation.create!(name: "LC", slug: "lc-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "k",
                                   default_locale: "en", locales: %w[en es],
                                   cards: [ { "cid" => "c1", "type" => "open_ended", "text" => "Why?" } ])
  end

  test "a pending line is never stale — there is no decision to lapse" do
    row = @survey.language_checks.create!(cid: "c1", locale: "es", status: "pending",
                                          content_digest: "old")
    assert_not row.stale_for?("new")
    assert_equal "pending", LanguageCheck.state_for(row, "new")
  end

  test "an approval lapses when its own words change" do
    row = @survey.language_checks.create!(cid: "c1", locale: "es", status: "approved",
                                          content_digest: "abc")
    assert_not row.stale_for?("abc")
    assert row.stale_for?("def")
    assert_equal "stale", LanguageCheck.state_for(row, "def")
  end

  test "an approval lapses when the primary language underneath it changes" do
    row = @survey.language_checks.create!(cid: "c1", locale: "es", status: "approved",
                                          content_digest: "abc", source_digest: "src1")
    assert_not row.stale_for?("abc", "src1")
    assert row.stale_for?("abc", "src2"),
           "approving a translation is a judgement about fidelity to a source"
  end

  test "a row decided before source digests were recorded keeps its tick" do
    # The honest answer for a row with no source_digest is "we cannot tell",
    # and silently lapsing every historic approval would be a worse answer.
    row = @survey.language_checks.create!(cid: "c1", locale: "es", status: "approved",
                                          content_digest: "abc", source_digest: nil)
    assert_not row.stale_for?("abc", "src2")
  end

  test "a changes-requested line also lapses, so a fix is visible as unread" do
    row = @survey.language_checks.create!(cid: "c1", locale: "es", status: "changes_requested",
                                          content_digest: "abc")
    assert_equal "stale", LanguageCheck.state_for(row, "def")
  end

  test "a line with no row at all is pending" do
    assert_equal "pending", LanguageCheck.state_for(nil, "abc")
  end

  test "one row per card per language is enforced by the database" do
    @survey.language_checks.create!(cid: "c1", locale: "es", status: "approved")
    assert_raises(ActiveRecord::RecordNotUnique) do
      LanguageCheck.insert!({ survey_id: @survey.id, cid: "c1", locale: "es", status: "pending",
                              edit_revision: 0, created_at: Time.current, updated_at: Time.current })
    end
  end

  test "an unknown status is refused by the database, not only the model" do
    assert_raises(ActiveRecord::StatementInvalid) do
      LanguageCheck.insert!({ survey_id: @survey.id, cid: "c1", locale: "es", status: "looks_fine",
                              edit_revision: 0, created_at: Time.current, updated_at: Time.current })
    end
  end

  test "for_line does not write a row just because a line was looked at" do
    row = LanguageCheck.for_line(@survey, "c1", "es")
    assert row.new_record?, "rendering a deck must not write a row per line"
    assert_equal 0, LanguageCheck.where(survey: @survey).count
  end

  test "a review record outlives the link it arrived through" do
    link = @survey.language_check_links.create!(name: "Marta")
    row  = @survey.language_checks.create!(cid: "c1", locale: "es", status: "approved",
                                           language_check_link: link, reviewed_by_name: "Marta")
    link.destroy!
    assert_equal "approved", row.reload.status
    assert_equal "Marta", row.reviewed_by_name, "who checked it is not revoked with their link"
    assert_nil row.language_check_link_id
  end

  test "a signed-in reviewer's account name is preferred over a typed one" do
    user = User.create!(name: "Nick", email_address: "n-#{SecureRandom.hex(3)}@test.com",
                        password: "verylongpassword")
    row = @survey.language_checks.create!(cid: "c1", locale: "es", status: "approved",
                                          reviewed_by_user: user, reviewed_by_name: "typed")
    assert_equal "Nick", row.reviewer_label
  end

  test "deleting a Verto takes its review state with it" do
    link = @survey.language_check_links.create!
    @survey.language_checks.create!(cid: "c1", locale: "es", status: "approved", language_check_link: link)
    @survey.language_check_notes.create!(cid: "c1", locale: "es", body: "note", language_check_link: link)

    @survey.destroy!
    assert_equal 0, LanguageCheck.count
    assert_equal 0, LanguageCheckNote.count
    assert_equal 0, LanguageCheckLink.count
  end
end
