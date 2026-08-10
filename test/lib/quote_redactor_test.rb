require "test_helper"

# The deterministic half of quote safety.
#
# QuoteRedactor is not asked to be clever — OpenTextThemer and a human reviewer
# handle the judgement calls. It is asked to guarantee that certain shapes never
# survive, identically, every time. These tests pin those shapes.
class QuoteRedactorTest < ActiveSupport::TestCase
  def redacted(text) = QuoteRedactor.redact(text).text

  test "strips email addresses" do
    out = redacted("You can reach me at maria.rivas+play@example.co.uk about this whole thing")
    assert_not_includes out, "maria.rivas"
    assert_not_includes out, "example.co.uk"
    assert_includes out, QuoteRedactor::REDACTION
  end

  test "strips URLs with and without a scheme" do
    assert_not_includes redacted("Read more at https://mysite.example.com/a/b?c=d and decide yourself"),
                        "mysite.example.com"
    assert_not_includes redacted("It is all explained on www.example.org/page for anyone curious"),
                        "example.org"
  end

  test "strips phone numbers in several shapes" do
    [
      "Call me on +56 9 1234 5678 whenever you like",
      "My number is (021) 555-0199 if you want to talk",
      "ring 020 7946 0958 during the day please"
    ].each do |text|
      out = redacted(text)
      assert_includes out, QuoteRedactor::REDACTION, "not redacted: #{text}"
      assert_no_match(/\d{4}/, out, "digits survived: #{text}")
    end
  end

  test "strips social handles" do
    assert_not_includes redacted("Follow @maria_rivas_23 for the campaign updates we run"), "maria_rivas"
  end

  test "strips bare identifier-length digit runs" do
    out = redacted("My student number is 20387461 and nobody ever asks about it")
    assert_not_includes out, "20387461"
  end

  test "keeps ordinary numbers that are not identifiers" do
    out = redacted("I think about 60 percent of my friends feel the same way as I do")
    assert_includes out, "60"
    assert_not_includes out, QuoteRedactor::REDACTION
  end

  test "drops an answer that is mostly redaction" do
    result = QuoteRedactor.redact("a@b.com c@d.com e@f.com")
    assert_not result.kept?
    assert_equal :over_redacted, result.dropped
  end

  test "drops answers that are too short to be a finding" do
    assert_equal :too_short, QuoteRedactor.redact("Yes").dropped
    assert_equal :blank, QuoteRedactor.redact("   ").dropped
  end

  test "rejects rather than truncates an over-long answer" do
    result = QuoteRedactor.redact("a" * (CorpusQuote::MAX_LENGTH + 1))
    assert_not result.kept?, "a long answer must be dropped, not cut down to size"
    assert_equal :too_long, result.dropped
  end

  test "flattens newlines so a multi-line answer redacts predictably" do
    assert_equal "I want a job that helps people. And somewhere to live.",
                 redacted("I want a job that helps people.\n\nAnd somewhere to live.")
  end

  test "redact_all keeps survivors, de-duplicates, and counts the reasons" do
    kept, drops = QuoteRedactor.redact_all([
      "I dream of a city where the air is clean and people care",
      "I dream of a city where the air is clean and people care",   # duplicate
      "no",                                                          # too short
      "hello@example.com or 555 123 9987 or @me_here",               # over-redacted
      nil
    ])

    assert_equal 1, kept.size
    assert_equal 1, drops[:too_short]
    assert_equal 1, drops[:blank]
    assert_equal 1, drops[:over_redacted]
  end

  # One redaction inside an otherwise ordinary sentence is a SUCCESS, not a
  # rejection: the identifier is gone and what the respondent said survives.
  # Dropping these would quietly throw away most of the usable quotes.
  test "keeps a sentence that needed a single redaction" do
    out = redacted("Write to me at hello@example.com if you want to help with the campaign")
    assert_includes out, "if you want to help with the campaign"
    assert_not_includes out, "hello@example.com"
  end

  test "a real Spanish answer from the supplied dataset survives intact" do
    original = "Que la gente deje de pensar que no sirve de nada lo que hace una sola persona."
    assert_equal original, redacted(original)
  end
end
