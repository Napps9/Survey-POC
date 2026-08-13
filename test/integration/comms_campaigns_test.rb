require "test_helper"

class CommsCampaignsTest < ActionDispatch::IntegrationTest
  PASSWORD = "verylongpassword".freeze
  PNG_DATA_URL = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==".freeze

  def setup
    @playverto = Organisation.find_or_create_by!(slug: CommsAccess::PLAYVERTO_SLUG) do |o|
      o.name = "Playverto"
    end
    @staff = User.create!(name: "Staff", email_address: "cc-staff-#{SecureRandom.hex(3)}@test.com",
                          password: PASSWORD)
    @playverto.memberships.create!(user: @staff, role: "member")

    @outsider = User.create!(name: "Out", email_address: "cc-out-#{SecureRandom.hex(3)}@test.com",
                             password: PASSWORD)
    org = Organisation.create!(name: "Other", slug: "cc-#{SecureRandom.hex(3)}")
    org.memberships.create!(user: @outsider, role: "admin")
  end

  def sign_in(user)
    post session_path, params: { email_address: user.email_address, password: PASSWORD }
    follow_redirect! if response.redirect?
  end

  def create_campaign
    post comms_campaigns_path
    EmailCampaign.order(:id).last
  end

  test "create seeds a starter document and lands in the builder" do
    sign_in @staff

    assert_difference "EmailCampaign.count", 1 do
      post comms_campaigns_path
    end
    campaign = EmailCampaign.order(:id).last
    assert_redirected_to edit_comms_campaign_path(campaign)
    assert_equal %w[heading text button], campaign.document["blocks"].map { |b| b["type"] }

    follow_redirect!
    assert_response :success
    assert_match "comms-paper", response.body
    assert_match "rich-text-toolbar", response.body
  end

  test "autosave round-trips the design and only touches present keys" do
    sign_in @staff
    campaign = create_campaign

    design = {
      "version" => 1,
      "settings" => { "contentWidth" => 480 },
      "blocks" => [
        { "id" => "b_1", "type" => "heading", "text" => "Hello friend", "level" => 2,
          "text_html" => "Hello <b>friend</b>" },
        { "id" => "b_2", "type" => "marquee", "text" => "dropped" }
      ]
    }
    patch comms_campaign_path(campaign), params: { title: "August news", design: design },
                                         as: :json
    assert_response :success
    body = JSON.parse(response.body)
    assert body["ok"]

    campaign.reload
    assert_equal "August news", campaign.title
    assert_equal 480, campaign.document["settings"]["contentWidth"]
    assert_equal [ "heading" ], campaign.document["blocks"].map { |b| b["type"] }
    assert_equal "Hello <b>friend</b>", campaign.document["blocks"][0]["text_html"]

    # A payload without design must leave it untouched.
    patch comms_campaign_path(campaign), params: { subject: "The subject" }, as: :json
    assert_response :success
    campaign.reload
    assert_equal "The subject", campaign.subject
    assert_equal 1, campaign.document["blocks"].size

    # A blank title is dropped, not saved.
    patch comms_campaign_path(campaign), params: { title: "" }, as: :json
    assert_equal "August news", campaign.reload.title
  end

  test "the save response carries the inbox-row review so the panel can paint it" do
    campaign = EmailCampaign.create!(title: "Review me", design: { "blocks" => [] })
    sign_in @staff

    patch comms_campaign_path(campaign),
          params: { subject: "BIG NEWS!!!", preheader: "" }, as: :json
    assert_response :success

    review = response.parsed_body["subject_review"]
    assert review.present?, "the review rides back on the same save the panel already makes"
    assert_includes review.map { |n| n["text"] }.join(" "), "capitals"
    assert_equal [ "warn" ], review.select { |n| n["text"].include?("top of the email") }.map { |n| n["level"] }

    # Advisory only — it must never become a send gate.
    patch comms_campaign_path(campaign),
          params: { subject: "A calm, clear subject", preheader: "With a second line." }, as: :json
    assert_empty response.parsed_body["subject_review"]
  end

  test "a drifted html twin is not stored" do
    sign_in @staff
    campaign = create_campaign

    patch comms_campaign_path(campaign), params: {
      design: { "blocks" => [ { "type" => "text", "text" => "Real",
                                "text_html" => "<b>Forged content</b>" } ] }
    }, as: :json

    assert_not campaign.reload.document["blocks"][0].key?("text_html")
  end

  test "preview renders the compiled artifact with the unsubscribe stub" do
    sign_in @staff
    campaign = create_campaign

    get preview_comms_campaign_path(campaign)
    assert_response :success
    assert_match(/role="presentation"/, response.body)
    assert_match(/href="#"/, response.body)
    assert_no_match(/\{\{unsubscribe_url\}\}/, response.body)
  end

  test "image endpoint stores the upload and returns a blob path" do
    sign_in @staff
    campaign = create_campaign

    post image_comms_campaign_path(campaign), params: { image: PNG_DATA_URL }, as: :json
    assert_response :success
    body = JSON.parse(response.body)
    assert body["ok"]
    assert_match %r{^/rails/active_storage/}, body["url"]
    assert_equal 1, campaign.reload.images.count
  end

  test "moderation endpoint fails open when no moderator is configured" do
    sign_in @staff
    campaign = create_campaign

    stub_method(ImageModerator, :configured?, false) do
      post moderate_image_comms_campaign_path(campaign), params: { image: PNG_DATA_URL }, as: :json
    end
    assert_response :success
    assert JSON.parse(response.body)["ok"]
  end

  test "a campaign past draft or scheduled refuses edits with 423" do
    sign_in @staff
    campaign = create_campaign
    campaign.update_column(:status, "sent")

    patch comms_campaign_path(campaign), params: { title: "Too late" }, as: :json
    assert_response :locked
    assert_not_equal "Too late", campaign.reload.title

    post image_comms_campaign_path(campaign), params: { image: PNG_DATA_URL }, as: :json
    assert_response :locked

    # The builder still opens read-only.
    get edit_comms_campaign_path(campaign)
    assert_response :success
    assert_no_match "contenteditable", response.body
  end

  test "destroy removes the campaign and returns to the list" do
    sign_in @staff
    campaign = create_campaign

    assert_difference "EmailCampaign.count", -1 do
      delete comms_campaign_path(campaign)
    end
    assert_redirected_to comms_path
    assert_equal I18n.t("flash.comms.campaign_deleted"), flash[:notice]
  end

  test "every campaign route 404s for a signed-in non-member" do
    sign_in @staff
    campaign = create_campaign
    delete session_path

    sign_in @outsider
    [ [ :get, edit_comms_campaign_path(campaign) ],
      [ :patch, comms_campaign_path(campaign) ],
      [ :get, preview_comms_campaign_path(campaign) ],
      [ :post, image_comms_campaign_path(campaign) ] ].each do |verb, path|
      send(verb, path)
      assert_response :not_found, "#{verb} #{path} should 404 for non-members"
    rescue ActionController::RoutingError
      assert true
    end
  end
end
