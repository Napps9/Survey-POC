require "test_helper"

class CommsListsTest < ActionDispatch::IntegrationTest
  PASSWORD = "verylongpassword".freeze

  def setup
    @playverto = Organisation.find_or_create_by!(slug: CommsAccess::PLAYVERTO_SLUG) do |o|
      o.name = "Playverto"
    end
    @staff = User.create!(name: "Staff", email_address: "cl-staff-#{SecureRandom.hex(3)}@test.com",
                          password: PASSWORD)
    @playverto.memberships.create!(user: @staff, role: "member")
    sign_in @staff
  end

  def sign_in(user)
    post session_path, params: { email_address: user.email_address, password: PASSWORD }
    follow_redirect! if response.redirect?
  end

  test "pasted import creates contacts, skips junk, dedupes and counts" do
    post comms_lists_path, params: {
      name: "Newsletter",
      emails_text: "one@example.org, Jo\nnot-an-email\nTWO@example.org\ntwo@example.org\n"
    }

    list = EmailList.order(:id).last
    assert_redirected_to comms_list_path(list)
    assert_equal 2, list.contacts_count
    assert_equal %w[one@example.org two@example.org], list.email_list_contacts.pluck(:email).sort
    assert_equal "Jo", list.email_list_contacts.find_by(email: "one@example.org").name

    follow_redirect!
    assert_match "skipped: 2", response.body
  end

  test "CSV import reads email and name columns and skips a header row" do
    csv = "email,name\nthree@example.org,Three\nfour@example.org,\n"
    file = Rack::Test::UploadedFile.new(StringIO.new(csv), "text/csv", original_filename: "list.csv")

    post comms_lists_path, params: { name: "CSV list", csv: file }

    list = EmailList.order(:id).last
    assert_equal 2, list.contacts_count
    assert_equal "Three", list.email_list_contacts.find_by(email: "three@example.org").name
  end

  test "an import with no addresses does not create a list" do
    assert_no_difference "EmailList.count" do
      post comms_lists_path, params: { name: "Empty", emails_text: "" }
    end
    assert_redirected_to comms_lists_path
  end

  test "destroy removes the list and its contacts" do
    post comms_lists_path, params: { name: "Doomed", emails_text: "x@example.org" }
    list = EmailList.order(:id).last

    assert_difference [ "EmailList.count", "EmailListContact.count" ], -1 do
      delete comms_list_path(list)
    end
    assert_equal I18n.t("flash.comms.list_deleted"), flash[:notice]
  end

  test "audience_count endpoint reflects the resolver, minus suppressions" do
    post comms_campaigns_path
    campaign = EmailCampaign.order(:id).last

    post comms_lists_path, params: { name: "Count", emails_text: "a@example.org\nb@example.org" }
    list = EmailList.order(:id).last
    EmailSuppression.record!("b@example.org", reason: "unsubscribe")

    post audience_count_comms_campaign_path(campaign),
         params: { audience: { kind: "list", list_id: list.id } }, as: :json
    assert_response :success
    assert_equal 1, JSON.parse(response.body)["count"]
  end

  test "lists are 404 for non-members" do
    delete session_path
    outsider = User.create!(name: "Out", email_address: "cl-out-#{SecureRandom.hex(3)}@test.com",
                            password: PASSWORD)
    Organisation.create!(name: "O", slug: "cl-o-#{SecureRandom.hex(3)}")
                .memberships.create!(user: outsider, role: "admin")
    sign_in outsider

    get comms_lists_path
    assert_response :not_found
  rescue ActionController::RoutingError
    assert true
  end
end
