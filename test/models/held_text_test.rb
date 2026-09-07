require "test_helper"

class HeldTextTest < ActiveSupport::TestCase
  def setup
    @org    = Organisation.create!(name: "O", slug: "ht-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                                   default_locale: "en", locales: [ "en" ],
                                   cards: [ { "type" => "open_ended", "text" => "Why?" },
                                            { "type" => "multiple_choice", "text" => "Pick", "options" => %w[A B], "allow_other" => true } ])
    @resp = @survey.responses.create!(
      session_token: SecureRandom.uuid, status: "started",
      answers: { "0" => { "type" => "open_ended", "value" => nil, "held" => { "value" => true } },
                 "1" => { "type" => "multiple_choice", "value" => nil, "other" => nil, "held" => { "other" => true } } }
    )
  end

  def hold!(card_index:, slot:, text:, **attrs)
    @resp.held_texts.create!(survey: @survey, organisation: @org, card_index:, slot:, text:,
                             text_digest: HeldText.digest_for(text), question: "Q", **attrs)
  end

  test "release! puts the text back where it was typed and clears the marker" do
    held = hold!(card_index: 0, slot: "value", text: "because it matters")

    held.release!(decided_by: "staff@example.com", note: "fine")

    entry = @resp.reload.answers["0"]
    assert_equal "because it matters", entry["value"]
    assert_not entry.key?("held")
    assert_equal "released", held.reload.status
    assert_equal "staff@example.com", held.decided_by_email
    assert_not held.auto?
    assert held.decided_at.present?
  end

  test "release! of an Other write-in leaves the choice slot alone" do
    held = hold!(card_index: 1, slot: "other", text: "something else")

    held.release!(auto: true)

    entry = @resp.reload.answers["1"]
    assert_equal "something else", entry["other"]
    assert_nil entry["value"]
    assert_not entry.key?("held")
    assert held.reload.auto?
  end

  test "remove! leaves a removed marker, keeps the text for the retention window" do
    held = hold!(card_index: 0, slot: "value", text: "12 Acacia Avenue, flat 3")

    held.remove!(auto: true, note: "identifying")

    entry = @resp.reload.answers["0"]
    assert_nil entry["value"]
    assert_equal({ "value" => "removed" }, entry["held"])
    assert_equal "removed", held.reload.status
    assert_equal "12 Acacia Avenue, flat 3", held.text
    assert_in_delta Moderation::REMOVED_RETENTION.from_now, held.purge_after, 5.seconds
    assert Response.answered_entry?(entry), "a removed answer was still given"
  end

  test "a superseded row's late decision does not write stale text into the answer" do
    old  = hold!(card_index: 0, slot: "value", text: "first draft", status: "superseded")
    hold!(card_index: 0, slot: "value", text: "second thoughts")

    old.release!(auto: true)

    assert_equal "released", old.reload.status, "the row's own status still moves"
    entry = @resp.reload.answers["0"]
    assert_nil entry["value"], "the newer text is what the marker stands for"
    assert_equal({ "value" => true }, entry["held"])
  end

  test "only the newest non-superseded row for a slot is current" do
    a = hold!(card_index: 0, slot: "value", text: "a", status: "superseded")
    b = hold!(card_index: 0, slot: "value", text: "b")

    assert_not a.current_for_slot?
    assert b.current_for_slot?
  end

  test "the digest ignores surrounding whitespace and nothing else" do
    assert_equal HeldText.digest_for("hello"), HeldText.digest_for("  hello \n")
    assert_not_equal HeldText.digest_for("hello"), HeldText.digest_for("Hello")
  end

  test "the text is encrypted at rest" do
    held = hold!(card_index: 0, slot: "value", text: "my secret answer")

    raw = HeldText.connection.select_value("SELECT text FROM held_texts WHERE id = #{held.id}")
    assert_not_includes raw.to_s, "my secret answer"
    assert_equal "my secret answer", held.reload.text
  end

  test "one row per text per slot per response" do
    hold!(card_index: 0, slot: "value", text: "same")

    assert_raises(ActiveRecord::RecordNotUnique) do
      ActiveRecord::Base.transaction(requires_new: true) do
        hold!(card_index: 0, slot: "value", text: "same")
      end
    end
  end

  test "status and slot are closed sets, in the model and in the database" do
    held = hold!(card_index: 0, slot: "value", text: "x")

    assert_not @resp.held_texts.build(slot: "value", text_digest: "d", status: "archived", card_index: 0).valid?
    assert_not @resp.held_texts.build(slot: "middle", text_digest: "d", card_index: 0).valid?

    assert_raises(ActiveRecord::StatementInvalid) do
      ActiveRecord::Base.transaction(requires_new: true) do
        ActiveRecord::Base.connection.execute("UPDATE held_texts SET status = 'archived' WHERE id = #{held.id}")
      end
    end
    assert_includes ActiveRecord::Base.connection.check_constraints(:held_texts).map(&:name), "chk_held_texts_status"
    assert_includes ActiveRecord::Base.connection.check_constraints(:surveys).map(&:name), "chk_surveys_moderation_mode"
  end

  test "a response takes its held texts with it; so does a survey and an organisation" do
    hold!(card_index: 0, slot: "value", text: "x")
    assert_difference -> { HeldText.count }, -1 do
      @resp.destroy!
    end

    resp2 = @survey.responses.create!(session_token: SecureRandom.uuid, status: "started")
    resp2.held_texts.create!(survey: @survey, organisation: @org, card_index: 0, slot: "value", text: "y",
                             text_digest: HeldText.digest_for("y"))
    assert_difference -> { HeldText.count }, -1 do
      @org.destroy!
    end
  end
end
