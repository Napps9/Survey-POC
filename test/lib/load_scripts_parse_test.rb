require "test_helper"
require "open3"

# The k6 scripts are ES modules that import from "k6/…", so nothing in this
# app ever loads them and a syntax error only surfaces on a GitHub runner, as
# every generator failing at once. `node --check` is NOT a gate for them: on a
# .js file it assumes CommonJS, gives up at the first `import`, and exits 0 —
# it passed a file with an unterminated regex (2026-09-08). Forcing an ES
# module parse from stdin is what actually catches it.
class LoadScriptsParseTest < ActiveSupport::TestCase
  SCRIPTS = %w[test/load/journey.js test/load/ping.js].freeze

  SCRIPTS.each do |script|
    test "#{script} parses as an ES module" do
      skip "node is not installed here" unless system("node", "--version", out: File::NULL, err: File::NULL)

      _out, err, status = Open3.capture3("node", "--input-type=module", "--check",
                                         stdin_data: Rails.root.join(script).read)
      assert status.success?, "#{script} does not parse:\n#{err}"
    end
  end
end
