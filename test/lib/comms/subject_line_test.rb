require "test_helper"

# The inbox-row rules. Pure functions over two strings, so these assert the
# judgement calls directly — including the ones deliberately NOT made.
class Comms::SubjectLineTest < ActiveSupport::TestCase
  def review(subject, preheader = "A perfectly good second line.")
    Comms::SubjectLine.review(subject: subject, preheader: preheader)
  end

  def texts(notes) = notes.map { |n| n["text"] }.join(" | ")

  test "a good subject and preheader raise nothing at all" do
    assert_empty review("Imports that keep their columns straight",
                        "Plus a faster results page.")
  end

  test "an empty subject is a warning, not a tip — the send is refused" do
    notes = review("")
    assert_equal "warn", notes.first["level"]
    assert_match(/empty/, notes.first["text"])
  end

  test "the phone cut-off is shown, never nagged about" do
    # Almost every good subject passes 35 characters; the preview card is
    # where that gets communicated, so no note fires for it.
    assert_empty review("A subject that runs past a phone's cut-off point")
  end

  test "length notes escalate from desktop to hopeless" do
    assert_empty review("Short and sweet subject").select { |n| n["text"].include?("characters") }

    desktop = review("A subject line that is quite a lot longer than any desktop client will ever show")
    assert_match(/cut off on most desktop clients/, texts(desktop))

    hopeless = review("#{"A very long subject indeed " * 5}end")
    assert_equal "warn", hopeless.first["level"]
    assert_match(/cut off everywhere/, texts(hopeless))
  end

  test "shouting, repeated punctuation and emoji pile-ups are flagged" do
    assert_match(/capitals/, texts(review("URGENT news for you")))
    assert_match(/punctuation/, texts(review("Big news!!!")))
    assert_match(/emoji/, texts(review("Big news 🎉🚀🔥")))

    # One emoji is fine, and VERTO is the product, not shouting.
    assert_empty review("A new VERTO feature 🎉")
  end

  test "a missing preheader warns, because the client falls back to the masthead" do
    notes = Comms::SubjectLine.review(subject: "A fine subject", preheader: "")
    assert_equal "warn", notes.first["level"]
    assert_match(/top of the email/, notes.first["text"])
  end

  test "a preheader that just repeats the subject is a wasted line" do
    notes = Comms::SubjectLine.review(subject: "Imports that keep their columns straight",
                                      preheader: "Imports that keep their columns straight")
    assert_match(/repeats the subject/, texts(notes))

    # Sharing a word or two is not repetition.
    assert_no_match(/repeats the subject/,
                    texts(Comms::SubjectLine.review(subject: "Imports keep their columns straight",
                                                    preheader: "And results load faster now.")))
  end

  test "an over-long preheader is a tip" do
    notes = Comms::SubjectLine.review(subject: "Fine", preheader: "x" * 200)
    assert_match(/most clients stop/, texts(notes))
  end

  test "no spam-word folklore: ordinary sales words pass clean" do
    assert_empty review("Your free trial of the new report builder",
                        "It opens today and runs for a month.")
  end

  test "truncate_for cuts at the client's width with an ellipsis" do
    assert_equal "Short", Comms::SubjectLine.truncate_for("Short", 35)
    assert_equal "Exactly the first ten…",
                 Comms::SubjectLine.truncate_for("Exactly the first ten words go here and more", 21)
  end
end
