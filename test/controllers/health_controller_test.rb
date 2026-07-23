require "test_helper"

class HealthControllerTest < ActionDispatch::IntegrationTest
  test "200 when the database is reachable" do
    get "/up"
    assert_response :success
  end

  test "503 when the database connection can't be verified" do
    stub_method(ActiveRecord::Base, :with_connection, ->(&_blk) { raise ActiveRecord::ConnectionNotEstablished, "down" }) do
      get "/up"
    end
    assert_response :service_unavailable
  end
end
