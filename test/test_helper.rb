ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

class ActiveSupport::TestCase
  parallelize(workers: 1)

  # Verto creation and the other AI paths enqueue jobs rather than running
  # inline (P0-3). The suite uses the :test adapter, so a test that cares about
  # the RESULT of that work wraps the request in perform_enqueued_jobs, and a
  # test that cares about the hand-off asserts on enqueued_jobs instead.
  include ActiveJob::TestHelper

  # Creation and the imports hand off to a background job: the request redirects
  # to a wait screen, which forwards on once the job lands. Walk that chain so a
  # test can go on asserting the destination it always did.
  def follow_verto_build!
    follow_redirect! while response.redirect? && response.location.include?("/verto_builds/")
  end

  # Temporarily replace a singleton (class/instance) method for the duration of
  # the block, restoring it afterwards. A lightweight stand-in for minitest's
  # Object#stub, which this minitest version doesn't ship. `return_value` may be
  # a plain value or a callable (invoked with the call args).
  def stub_method(object, name, return_value = nil)
    impl     = return_value.respond_to?(:call) ? return_value : ->(*_a, **_k, &_b) { return_value }
    original = object.method(name)
    object.define_singleton_method(name) { |*args, **kw, &blk| impl.call(*args, **kw, &blk) }
    yield
  ensure
    object.singleton_class.send(:remove_method, name)
    object.define_singleton_method(name, original) if original
  end
end
