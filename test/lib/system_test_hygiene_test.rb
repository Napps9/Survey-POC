require "test_helper"

# Idioms that cost the system suite minutes, kept out by a test rather than by
# memory. Each one below was measured before it was banned.
class SystemTestHygieneTest < ActiveSupport::TestCase
  SYSTEM_TESTS = Rails.root.glob("test/system/**/*_test.rb")

  test "the consent gate is passed with agree_to_consent_gate, not a three-second guard" do
    # `click_button "Agree & continue" if has_button?(..., wait: 3)` waits its
    # full three seconds on every deck that has no gate — nearly every fixture
    # deck. agree_to_consent_gate reads the server-rendered gate instead.
    offenders = SYSTEM_TESTS.select { |f| f.read.include?('if has_button?("Agree & continue"') }

    assert_empty offenders.map { |f| f.relative_path_from(Rails.root).to_s },
      "guard the consent gate with agree_to_consent_gate (test/application_system_test_case.rb)"
  end

  test "a file a system test writes is named per test or per process" do
    # public/ and tmp/ are shared by every parallel worker, so a fixed name is
    # a collision waiting for a second worker.
    offenders = SYSTEM_TESTS.select do |f|
      f.read.scan(/["'](?:public|tmp)\/[^"']*["']/).any? { |lit| !lit.include?("\#{") }
    end

    assert_empty offenders.map { |f| f.relative_path_from(Rails.root).to_s },
      "name files written under public/ or tmp/ with SecureRandom or Process.pid"
  end
end
