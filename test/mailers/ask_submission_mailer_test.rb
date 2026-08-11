require "test_helper"

class AskSubmissionMailerTest < ActionMailer::TestCase
  def setup
    @org  = Organisation.create!(name: "Anglo American Foundation", slug: "am-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "Nick Apps", email_address: "am-#{SecureRandom.hex(4)}@test.com",
                         password: "verylongpassword")
    @survey = @org.surveys.create!(
      title: "Wellbeing Check-in", theme: "Well-being", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "multiple_choice", "cid" => "c_own", "text" => "How happy are you?",
          "options" => %w[Happy Neutral] },
        { "type" => "multiple_choice", "cid" => "c_common", "text" => "How safe do you feel?",
          "options" => %w[Safe Unsafe], "common_question_set_id" => 77 }
      ]
    )
    3.times do
      @survey.responses.create!(session_token: SecureRandom.hex(8), status: "completed",
                                answers: { "0" => { "value" => "Happy" } })
    end
    @entry = CorpusEntry.create!(survey: @survey, organisation: @org,
                                 opted_in_at: Time.current, opted_in_by: @user)
  end

  test "team notification goes to the configured addresses and names the offer" do
    mail = AskSubmissionMailer.team_notification(@user, [ @entry ])

    assert_equal AskSubmissionMailer.team_recipients, mail.to
    assert_match "1 Verto submitted", mail.subject
    [ mail.html_part, mail.text_part ].each do |part|
      body = part.body.to_s
      assert_includes body, "Nick Apps"
      assert_includes body, "Wellbeing Check-in"
      assert_includes body, "all 2 questions"
    end
  end

  test "team notification distinguishes a narrowed question-set offer" do
    @entry.update!(offered_scope: { "own_questions" => false, "common_question_set_ids" => [ 77 ] })

    mail = AskSubmissionMailer.team_notification(@user, [ @entry ])

    assert_includes mail.text_part.body.to_s, "1 of 2 questions"
  end

  test "the default team addresses are the two the owner named" do
    assert_equal %w[nick@playverto.com Tech@playverto.com],
                 AskSubmissionMailer::TEAM_EMAILS.split(","),
      "ASK_REVIEW_EMAILS overrides this; the default is the standing instruction (2026-08-11)"
  end

  test "submitter confirmation is localised to the submitter's language" do
    @user.update!(preferred_locale: "fr")

    mail = AskSubmissionMailer.submitter_confirmation(@user, [ @entry ])

    assert_equal [ @user.email_address ], mail.to
    assert_equal I18n.t("ask_submission_mailer.confirmation_subject", locale: :fr), mail.subject
    assert_equal :en, I18n.locale, "the mailer must restore the surrounding locale"
  end

  test "an approval decision carries the Verto's name" do
    @entry.update!(review_status: "approved", reviewed_at: Time.current, reviewed_by_email: "t@t.com")

    mail = AskSubmissionMailer.decision(@entry)

    assert_equal [ @user.email_address ], mail.to
    assert_equal I18n.t("ask_submission_mailer.approved_subject", verto: "Wellbeing Check-in"), mail.subject
  end

  test "a decline decision carries the reviewer's note verbatim in both parts" do
    @entry.update!(review_status: "declined", reviewed_at: Time.current,
                   reviewed_by_email: "t@t.com", review_note: "Too much identifying free text.")

    mail = AskSubmissionMailer.decision(@entry)

    assert_equal I18n.t("ask_submission_mailer.declined_subject", verto: "Wellbeing Check-in"), mail.subject
    [ mail.html_part, mail.text_part ].each do |part|
      assert_includes part.body.to_s, "Too much identifying free text."
    end
  end

  test "a decision for an entry with no submitter is silently skipped" do
    @entry.update!(opted_in_by: nil, review_status: "approved",
                   reviewed_at: Time.current, reviewed_by_email: "t@t.com")

    assert_nil AskSubmissionMailer.decision(@entry).message.to
  end
end
