require "test_helper"
require Rails.root.join("lib/object_storage_origins")

class ObjectStorageOriginsTest < ActiveSupport::TestCase
  test "no bucket configured → no extra origins (local disk is all same-origin)" do
    assert_equal [], ObjectStorageOrigins.allowed({})
    assert_equal [], ObjectStorageOrigins.allowed("STORAGE_BUCKET" => "   ")
  end

  test "an R2 endpoint → its host in both path-style and virtual-hosted form" do
    env = { "STORAGE_BUCKET"   => "vertonow-storage",
            "STORAGE_ENDPOINT" => "https://abc123.eu.r2.cloudflarestorage.com",
            "STORAGE_REGION"   => "auto" }
    assert_equal [ "https://abc123.eu.r2.cloudflarestorage.com",
                   "https://*.abc123.eu.r2.cloudflarestorage.com" ],
                 ObjectStorageOrigins.allowed(env)
  end

  test "plain S3 (no endpoint) → the regional bucket hosts" do
    env = { "STORAGE_BUCKET" => "vertonow", "STORAGE_REGION" => "eu-central-1" }
    assert_equal [ "https://vertonow.s3.eu-central-1.amazonaws.com",
                   "https://s3.eu-central-1.amazonaws.com" ],
                 ObjectStorageOrigins.allowed(env)
  end

  test "S3 with R2's 'auto' region falls back to us-east-1 rather than a bogus host" do
    env = { "STORAGE_BUCKET" => "vertonow", "STORAGE_REGION" => "auto" }
    assert_equal [ "https://vertonow.s3.us-east-1.amazonaws.com",
                   "https://s3.us-east-1.amazonaws.com" ],
                 ObjectStorageOrigins.allowed(env)
  end

  test "a non-default port is kept; an unparseable endpoint adds nothing" do
    assert_equal [ "http://localhost:9000", "http://*.localhost:9000" ],
                 ObjectStorageOrigins.allowed("STORAGE_BUCKET" => "b", "STORAGE_ENDPOINT" => "http://localhost:9000")
    assert_equal [], ObjectStorageOrigins.allowed("STORAGE_BUCKET" => "b", "STORAGE_ENDPOINT" => "not a url")
    assert_equal [], ObjectStorageOrigins.allowed("STORAGE_BUCKET" => "b", "STORAGE_ENDPOINT" => "http://exa mple.com")
  end
end
