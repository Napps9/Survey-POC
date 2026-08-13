# frozen_string_literal: true

require "test_helper"
require_relative "../../bin/trello_client"

class TrelloWeekListTest < ActiveSupport::TestCase
  test "ordinal suffixes including the 11th-13th exceptions" do
    { 1 => "1st", 2 => "2nd", 3 => "3rd", 4 => "4th", 11 => "11th", 12 => "12th",
      13 => "13th", 21 => "21st", 22 => "22nd", 23 => "23rd", 31 => "31st" }
      .each { |n, expected| assert_equal expected, TrelloClient.ordinal(n) }
  end

  test "every day of a Monday-Sunday week maps to that Monday" do
    monday = Date.new(2026, 8, 10)
    (0..6).each { |offset| assert_equal monday, TrelloClient.week_monday(monday + offset) }
    # Sunday (wday 0) belongs to the week that started the previous Monday.
    assert_equal Date.new(2026, 8, 3), TrelloClient.week_monday(Date.new(2026, 8, 9))
  end

  test "weekly list names, including across a year boundary" do
    assert_equal "Done - Week of 10th August 2026",
                 TrelloClient.weekly_done_list_name(Date.new(2026, 8, 13))
    assert_equal "Done - Week of 31st August 2026",
                 TrelloClient.weekly_done_list_name(Date.new(2026, 9, 1))
    assert_equal "Done - Week of 28th December 2026",
                 TrelloClient.weekly_done_list_name(Date.new(2027, 1, 2))
  end

  test "card id embeds its creation time in UTC" do
    created = Time.utc(2026, 8, 10, 12, 30, 5)
    card_id = "#{created.to_i.to_s(16)}0000000000000000"
    assert_equal created, TrelloClient.card_created_at(card_id)
  end
end
