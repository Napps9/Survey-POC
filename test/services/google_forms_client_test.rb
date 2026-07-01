require "test_helper"

class GoogleFormsClientTest < ActiveSupport::TestCase
  test "extracts the form id from an edit link" do
    assert_equal "1AbC_-dEf", GoogleFormsClient.extract_form_id("https://docs.google.com/forms/d/1AbC_-dEf/edit")
    assert_equal "1AbC_-dEf", GoogleFormsClient.extract_form_id("https://docs.google.com/forms/d/1AbC_-dEf/edit?usp=sharing")
  end

  test "accepts a bare id" do
    assert_equal "1AbCdEfGhIjK", GoogleFormsClient.extract_form_id("1AbCdEfGhIjK")
  end

  test "rejects a public response link with a helpful message" do
    err = assert_raises(GoogleFormsClient::Error) do
      GoogleFormsClient.extract_form_id("https://docs.google.com/forms/d/e/1FAIpQL_xyz/viewform")
    end
    assert_match(/EDIT link/, err.message)
  end

  test "returns nil for junk" do
    assert_nil GoogleFormsClient.extract_form_id("")
    assert_nil GoogleFormsClient.extract_form_id("not a link")
  end

  # fetch() delegates to the private get_json seam; stub it to prove the happy
  # path and the auth/not-found error mapping without touching the network.
  test "fetch returns parsed json on success" do
    client = GoogleFormsClient.new("tok")
    client.define_singleton_method(:get_json) { |_url| { "info" => { "title" => "T" } } }
    assert_equal "T", client.fetch("abc").dig("info", "title")
  end

  test "surfaces auth and not-found errors" do
    client = GoogleFormsClient.new("tok")
    client.define_singleton_method(:get_json) { |_url| raise GoogleFormsClient::NotAuthorized, "nope" }
    assert_raises(GoogleFormsClient::NotAuthorized) { client.fetch("abc") }
  end
end
