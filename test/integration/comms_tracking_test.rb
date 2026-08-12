require "test_helper"

# The public engagement surface: open pixel, click redirect, unsubscribe.
# Everything keys on the recipient's random token; ids and other campaigns'
# links are dead ends.
class CommsTrackingTest < ActionDispatch::IntegrationTest
  def setup
    @campaign = EmailCampaign.create!(title: "T")
    @recipient = @campaign.email_campaign_recipients.create!(
      email: "r-#{SecureRandom.hex(3)}@example.org", status: "sent"
    )
    @link = @campaign.email_campaign_links.create!(url: "https://dest.example/page?a=1&b=2")
  end

  test "open returns the pixel, bumps counts, promotes to delivered, logs an event" do
    2.times { get comms_open_path(token: @recipient.token) }

    assert_response :success
    assert_equal "image/gif", response.media_type
    @recipient.reload
    assert_equal 2, @recipient.open_count
    assert_equal "delivered", @recipient.status
    assert_not_nil @recipient.first_opened_at
    assert_equal 2, EmailEvent.where(kind: "open", email_campaign_recipient_id: @recipient.id).count
  end

  test "click redirects to the stored URL and implies an open" do
    get comms_click_path(token: @recipient.token, link_id: @link.id)

    assert_redirected_to "https://dest.example/page?a=1&b=2"
    @recipient.reload
    assert_equal 1, @recipient.click_count
    assert_not_nil @recipient.first_opened_at
    assert_equal "delivered", @recipient.status
    assert_equal 1, EmailEvent.where(kind: "click").count
  end

  test "unknown tokens 404 on every endpoint" do
    get comms_open_path(token: "nope")
    assert_response :not_found

    get comms_click_path(token: "nope", link_id: @link.id)
    assert_response :not_found

    get comms_unsubscribe_path(token: "nope")
    assert_response :not_found
  end

  test "a link id from another campaign is a 404, not a redirect" do
    other = EmailCampaign.create!(title: "Other")
    foreign = other.email_campaign_links.create!(url: "https://elsewhere.example/")

    get comms_click_path(token: @recipient.token, link_id: foreign.id)
    assert_response :not_found
    assert_equal 0, @recipient.reload.click_count
  end

  test "GET unsubscribe confirms without acting; POST records once, idempotently" do
    get comms_unsubscribe_path(token: @recipient.token)
    assert_response :success
    assert_match @recipient.email, response.body
    assert_nil @recipient.reload.unsubscribed_at
    assert_equal 0, EmailSuppression.where(email: @recipient.email).count

    2.times { post comms_unsubscribe_path(token: @recipient.token) }
    assert_response :success
    @recipient.reload
    assert_not_nil @recipient.unsubscribed_at
    assert_equal 1, EmailSuppression.where(email: @recipient.email).count
    assert_equal 1, EmailEvent.where(kind: "unsubscribe").count
  end

  test "after unsubscribing, the resolver excludes the address end to end" do
    list = EmailList.create!(name: "L")
    list.email_list_contacts.create!(email: @recipient.email)

    post comms_unsubscribe_path(token: @recipient.token)

    rows = Comms::AudienceResolver.resolve({ "kind" => "list", "list_id" => list.id })
    assert_empty rows
  end

  test "tracking endpoints work without any signed-in session" do
    get comms_open_path(token: @recipient.token)
    assert_response :success
  end

  test "the unsubscribe page renders localized in every locale" do
    SupportedLocales.codes.each do |locale|
      get comms_unsubscribe_path(token: @recipient.token, locale: locale)
      assert_response :success, "locale #{locale} failed"
    end
  end
end
