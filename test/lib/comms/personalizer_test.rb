require "test_helper"

# Ports Temple's personalize.test.ts intent: unsubscribe swapped before
# anything else, link tokens resolved, pixel placed before </body>, and a
# second personalization pass is a no-op.
class Comms::PersonalizerTest < ActiveSupport::TestCase
  test "unsubscribe URL is swapped in html and text" do
    html = Comms::Personalizer.html(%(<a href="{{unsubscribe_url}}">u</a>),
                                    unsubscribe_url: "https://x/e/u/tok")
    text = Comms::Personalizer.text("Unsubscribe: {{unsubscribe_url}}",
                                    unsubscribe_url: "https://x/e/u/tok")

    assert_includes html, %(href="https://x/e/u/tok")
    assert_includes text, "Unsubscribe: https://x/e/u/tok"
  end

  test "link tokens resolve to per-recipient URLs; unknown ids fall to #" do
    html = Comms::Personalizer.html(%(<a href="{{link:7}}">go</a> <a href="{{link:9}}">?</a>),
                                    unsubscribe_url: "#",
                                    links: { 7 => "https://x/e/c/tok/7" })

    assert_includes html, %(href="https://x/e/c/tok/7")
    assert_includes html, %(href="#")
  end

  test "the unsubscribe link is never a click-wrap candidate" do
    frozen = %(<a href="{{unsubscribe_url}}">u</a><a href="{{link:1}}">go</a>)
    html = Comms::Personalizer.html(frozen, unsubscribe_url: "https://x/e/u/tok",
                                            links: { 1 => "https://x/e/c/tok/1" })

    assert_includes html, %(href="https://x/e/u/tok")
    assert_not_includes html, "e/c/tok/1\">u<"
  end

  test "pixel lands before </body>, or appends when absent" do
    with_body = Comms::Personalizer.html("<body>hi</body>", unsubscribe_url: "#",
                                         pixel_url: "https://x/e/o/tok")
    without = Comms::Personalizer.html("hi", unsubscribe_url: "#",
                                       pixel_url: "https://x/e/o/tok")

    assert_match %r{<img src="https://x/e/o/tok"[^>]*/></body>}, with_body
    assert_match %r{hi<img src="https://x/e/o/tok"}, without
  end

  test "personalizing twice is a no-op" do
    once = Comms::Personalizer.html(%(<body><a href="{{unsubscribe_url}}">u</a><a href="{{link:1}}">g</a></body>),
                                    unsubscribe_url: "https://x/u", links: { 1 => "https://x/c" },
                                    pixel_url: nil)
    twice = Comms::Personalizer.html(once, unsubscribe_url: "https://EVIL", links: { 1 => "https://EVIL" })

    assert_equal once, twice
  end
end
