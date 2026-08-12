require "test_helper"

class Comms::LinkExtractorTest < ActiveSupport::TestCase
  def setup
    @campaign = EmailCampaign.create!(title: "T")
  end

  test "absolute http(s) hrefs become link tokens backed by rows" do
    html = %(<a href="https://a.example/x">a</a> <a href="http://b.example/y">b</a>)
    out = Comms::LinkExtractor.extract!(@campaign, html)

    links = @campaign.email_campaign_links.order(:id)
    assert_equal [ "https://a.example/x", "http://b.example/y" ], links.map(&:url)
    assert_includes out, %(href="{{link:#{links.first.id}}}")
    assert_includes out, %(href="{{link:#{links.last.id}}}")
  end

  test "HTML entities are decoded before storing — the &amp;amp; bug" do
    html = %(<a href="https://a.example/x?p=1&amp;q=2">a</a>)
    Comms::LinkExtractor.extract!(@campaign, html)

    assert_equal "https://a.example/x?p=1&q=2", @campaign.email_campaign_links.sole.url
  end

  test "the same URL twice gets one row" do
    html = %(<a href="https://a.example/x">1</a><a href="https://a.example/x">2</a>)
    Comms::LinkExtractor.extract!(@campaign, html)

    assert_equal 1, @campaign.email_campaign_links.count
  end

  test "mailto and the unsubscribe placeholder pass through untouched" do
    html = %(<a href="mailto:x@y.z">m</a><a href="{{unsubscribe_url}}">u</a>)
    out = Comms::LinkExtractor.extract!(@campaign, html)

    assert_equal html, out
    assert_equal 0, @campaign.email_campaign_links.count
  end

  test "a second pass over tokenized output changes nothing" do
    html = %(<a href="https://a.example/x">a</a>)
    once = Comms::LinkExtractor.extract!(@campaign, html)
    twice = Comms::LinkExtractor.extract!(@campaign, once)

    assert_equal once, twice
    assert_equal 1, @campaign.email_campaign_links.count
  end
end
