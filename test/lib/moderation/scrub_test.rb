require "test_helper"

# The deterministic layer of free-text moderation: contact details are gone
# before an answer is stored, identically, every time, with no model and no
# job in the way.
class ModerationScrubTest < ActiveSupport::TestCase
  test "removes emails, phone numbers, URLs and handles, and counts each" do
    text, hits = Moderation::Scrub.call(
      "Email maria@example.com or call +44 20 7946 0958, see https://x.example/a/b or follow @maria_r ok"
    )

    assert_not_includes text, "maria@example.com"
    assert_not_includes text, "7946"
    assert_not_includes text, "x.example"
    assert_not_includes text, "maria_r"
    assert_includes text, "Email [removed] or call [removed], see [removed] or follow [removed] ok"
    assert_equal({ "email" => 1, "phone" => 1, "url" => 1, "handle" => 1 }, hits)
  end

  test "leaves ordinary numbers alone, unlike the quote redactor" do
    text, hits = Moderation::Scrub.call("I was born in 2009 and scored 10000 points")

    assert_equal "I was born in 2009 and scored 10000 points", text
    assert_empty hits
    # The redactor WOULD have removed the score: that difference is the point.
    assert_includes QuoteRedactor.redact("I was born in 2009 and scored 10000 points for the team").text, "[removed]"
  end

  test "returns the text unchanged with no hits when nothing matches" do
    text, hits = Moderation::Scrub.call("Que la gente deje de pensar que no sirve de nada.")

    assert_equal "Que la gente deje de pensar que no sirve de nada.", text
    assert_empty hits
  end

  test "answers: scrubs every free-text slot and nothing else" do
    cards = [
      { "type" => "open_ended", "text" => "Why?" },
      { "type" => "multiple_choice", "text" => "Pick", "options" => %w[A B], "allow_other" => true },
      { "type" => "contact_form", "text" => "Stay in touch" },
      { "type" => "open_ended", "text" => "Where?", "demographic" => true, "input" => "location" }
    ]
    answers = {
      "0" => { "type" => "open_ended", "value" => "write to a@b.com" },
      "1" => { "type" => "multiple_choice", "value" => "A", "other" => "ring 020 7946 0958" },
      "2" => { "type" => "contact_form", "value" => { "name" => "Lead", "email" => "lead@example.com" } },
      "3" => { "type" => "open_ended", "value" => "GB|Kent" },
      "9" => { "type" => "open_ended", "value" => "stray a@b.com" }
    }

    out, hits = Moderation::Scrub.answers(cards, answers)

    assert_equal "write to [removed]", out["0"]["value"]
    assert_equal "ring [removed]", out["1"]["other"]
    assert_equal "A", out["1"]["value"]
    assert_equal "lead@example.com", out["2"]["value"]["email"], "a contact form asks for the email on purpose"
    assert_equal "GB|Kent", out["3"]["value"]
    assert_equal "stray [removed]", out["9"]["value"], "a value at an index the deck lacks is still scrubbed"
    assert_equal({ "0" => { "email" => 1 }, "1" => { "phone" => 1 }, "9" => { "email" => 1 } }, hits)
    assert_equal "write to a@b.com", answers["0"]["value"], "the input hash is not mutated"
  end

  test "answers: passes non-hash input through" do
    assert_equal [ nil, {} ], Moderation::Scrub.answers([], nil)
    assert_equal [ "x", {} ], Moderation::Scrub.answers([], "x")
  end
end
