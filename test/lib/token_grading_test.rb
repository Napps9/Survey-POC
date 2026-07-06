require "test_helper"

# Token totals are computed entirely server-side from stored answers, so this
# locks the accrual rules for every answer type.
class TokenGradingTest < ActiveSupport::TestCase
  def card(type, extra = {})
    { "type" => type, "text" => "Q" }.merge(extra)
  end

  test "a question awards only when it carries a non-zero tokens/token_award key" do
    refute TokenGrading.awarding?({ "type" => "multiple_choice", "options" => %w[A B] })
    refute TokenGrading.awarding?({ "type" => "welcome_card", "tokens" => { "A" => { "gold" => 5 } } })
    refute TokenGrading.awarding?({ "type" => "token_checkpoint", "token_award" => { "gold" => 5 } })
    refute TokenGrading.awarding?(card("multiple_choice", "tokens" => { "A" => { "gold" => 0 } }))
    assert TokenGrading.awarding?(card("multiple_choice", "tokens" => { "A" => { "gold" => 5 } }))
    assert TokenGrading.awarding?(card("rating", "token_award" => { "gold" => 2 }))
    assert TokenGrading.awarding?(card("tap_card", "tokens" => { "Sky is blue" => { "yes" => { "gold" => 3 } } }))
  end

  test "single-choice / yes-no / image-grid award by exact canonical match" do
    %w[multiple_choice yes_no select_one_grid].each do |type|
      c = card(type, "tokens" => { "Blue" => { "gold" => 5 }, "Red" => { "coal" => 1 } })
      assert_equal({ "gold" => 5 }, TokenGrading.earned(c, "Blue"))
      assert_equal({ "coal" => 1 }, TokenGrading.earned(c, "Red"))
      assert_equal({}, TokenGrading.earned(c, "Green"))
      assert_equal({}, TokenGrading.earned(c, nil))
    end
  end

  test "multi-select sums the tokens for every chosen option" do
    c = card("select_many", "tokens" => { "Red" => { "gold" => 2 }, "Blue" => { "gold" => 3, "coal" => 1 } })
    assert_equal({ "gold" => 5, "coal" => 1 }, TokenGrading.earned(c, %w[Red Blue]))
    assert_equal({ "gold" => 2 }, TokenGrading.earned(c, %w[Red]))
    assert_equal({}, TokenGrading.earned(c, []))
    assert_equal({}, TokenGrading.earned(c, nil))
  end

  test "tap_card awards by each statement's swipe direction" do
    c = card("tap_card", "tokens" => {
      "Sky is blue"   => { "yes" => { "gold" => 3 }, "no" => { "coal" => 1 } },
      "Earth is flat" => { "no" => { "gold" => 2 } }
    })
    assert_equal({ "gold" => 5 }, TokenGrading.earned(c, { "Sky is blue" => "yes", "Earth is flat" => "no" }))
    assert_equal({ "coal" => 1 }, TokenGrading.earned(c, { "Sky is blue" => "no" }))
    assert_equal({}, TokenGrading.earned(c, {}))
  end

  test "scale/open/prioritise cards award a flat amount just for answering" do
    %w[range nps rating open_ended prioritise].each do |type|
      refute TokenGrading.awarding?(card(type)), "#{type}: no token_award key means unawarded"
    end

    c = card("rating", "token_award" => { "gold" => 2 })
    assert_equal({ "gold" => 2 }, TokenGrading.earned(c, 4))
    assert_equal({}, TokenGrading.earned(c, nil))
    assert_equal({}, TokenGrading.earned(c, ""))

    prioritise = card("prioritise", "token_award" => { "gold" => 1 })
    assert_equal({ "gold" => 1 }, TokenGrading.earned(prioritise, %w[A B]))
    assert_equal({}, TokenGrading.earned(prioritise, []))
  end

  test "totals sums every awarding card, seeded at 0 for every defined token type" do
    cards = [
      { "type" => "welcome_card" },
      card("multiple_choice", "tokens" => { "Blue" => { "gold" => 5 } }),
      { "type" => "open_ended", "text" => "feelings" }, # unawarded measurement Q
      card("rating", "token_award" => { "coal" => 2 })
    ]
    answers = {
      "1" => { "type" => "multiple_choice", "value" => "Blue" },
      "2" => { "type" => "open_ended", "value" => "anything" },
      "3" => { "type" => "rating", "value" => 4 }
    }
    totals = TokenGrading.totals(cards, answers, %w[gold coal diamond])
    assert_equal({ "gold" => 5, "coal" => 2, "diamond" => 0 }, totals)
  end
end
