require "test_helper"

# ApplicationHelper::PLAYER_PRELOAD_MODULES is the set of JS modules the
# player preloads from the <head> so a cold cache becomes interactive in one
# fetch wave (see layouts/_head). A stale list fails quietly — the lazy loader
# still works, the waterfall just comes back — so this pins the list to the
# source tree instead of trusting it.
class PlayerPreloadClosureTest < ActiveSupport::TestCase
  MODULES = ApplicationHelper::PLAYER_PRELOAD_MODULES

  test "every preloaded module exists on disk" do
    MODULES.each do |mod|
      assert Rails.root.join("app/javascript/#{mod}.js").exist?,
             "#{mod}.js is preloaded on /play but app/javascript/#{mod}.js does not exist (renamed or removed?)"
    end
  end

  test "the list is import-closed: preloaded modules only import preloaded modules" do
    # A controller that gains a new `import "lib/x"` re-opens a waterfall level
    # for exactly that module — the preload wave lands, then lib/x is fetched
    # after. Walk each listed file's static lib/controllers imports and insist
    # they're listed too. (Bare npm pins like @hotwired/* are preloaded by the
    # importmap itself and aren't checked here; lottie-web is deliberately
    # lazy — see the constant's comment.)
    MODULES.each do |mod|
      source = Rails.root.join("app/javascript/#{mod}.js").read
      source.scan(/from\s+"((?:lib|controllers)\/[^"]+)"/).flatten.each do |dep|
        assert_includes MODULES, dep,
                        "#{mod}.js imports #{dep}, which is not in PLAYER_PRELOAD_MODULES — add it, or the preload wave stops one fetch short"
      end
    end
  end

  test "controllers/index and the stimulus registry lead the list" do
    # These two are the second waterfall level for EVERY page boot — without
    # them the controller preloads arrive before the loader that uses them.
    assert_includes MODULES, "controllers/index"
    assert_includes MODULES, "controllers/application"
  end
end
