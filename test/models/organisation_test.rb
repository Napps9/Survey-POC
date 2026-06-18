require "test_helper"

class OrganisationTest < ActiveSupport::TestCase
  def build_org
    Organisation.new(name: "Logo Co", slug: "logo-#{SecureRandom.hex(3)}")
  end

  test "accepts a small PNG logo" do
    org = build_org
    org.logo.attach(io: StringIO.new("\x89PNG\r\n\x1a\n"), filename: "logo.png", content_type: "image/png")
    assert org.valid?, org.errors.full_messages.to_sentence
  end

  test "rejects a non-image logo" do
    org = build_org
    org.logo.attach(io: StringIO.new("not an image"), filename: "evil.txt", content_type: "text/plain")
    refute org.valid?
    assert_match(/image/i, org.errors.full_messages.to_sentence)
  end

  test "rejects an oversized logo" do
    org = build_org
    org.logo.attach(io: StringIO.new("a" * (Organisation::LOGO_MAX_BYTES + 1)),
                    filename: "huge.png", content_type: "image/png")
    refute org.valid?
    assert_match(/2 MB|smaller/i, org.errors.full_messages.to_sentence)
  end
end
