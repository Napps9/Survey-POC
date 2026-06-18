ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

class ActiveSupport::TestCase
  parallelize(workers: 1)

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
