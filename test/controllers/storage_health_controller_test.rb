require "test_helper"

class StorageHealthControllerTest < ActionDispatch::IntegrationTest
  test "200 and mounted:true when the check passes" do
    stub_method(StorageMountCheck, :mounted?, -> { true }) do
      get "/up/storage"
    end
    assert_response :success
    assert_equal true, JSON.parse(response.body)["mounted"]
  end

  test "503 and mounted:false when the disk isn't actually a separate mount" do
    stub_method(StorageMountCheck, :mounted?, -> { false }) do
      get "/up/storage"
    end
    assert_response :service_unavailable
    assert_equal false, JSON.parse(response.body)["mounted"]
  end
end
