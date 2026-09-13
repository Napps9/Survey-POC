ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

# Line filtering — `bin/rails test test/foo_test.rb:42` running the ONE test on
# line 42 — is installed by rails/test_unit/railtie, which
# config/application.rb leaves off. Without this the runner still parsed the
# :42, and then nothing applied it: the whole file ran, silently, from every
# rerun hint CI prints. Only the mixin is wanted, not the railtie: that would
# also move tailwindcss-rails' build hook off db:test:prepare, which CI runs.
require "rails/test_unit/line_filtering"
ActiveSupport::TestCase.extend Rails::LineFiltering

# Two things done once, here in the parent, before parallelize forks the
# workers — the same move test/application_system_test_case.rb makes for the
# Tailwind build. Both suites load this file, so both get them.
#
# wkhtmltopdf-binary gunzips its 47 MB binary into its own gem directory on
# first use with no lock — File.exist?, a streaming write, then exec (the gem's
# bin/wkhtmltopdf). Four forked workers meeting a fresh bundle at once, which
# is every CI run (the bundler cache holds the gzipped gem; extraction happens
# during the run), can exec a half-written file: "Exec format error", or an
# empty PDF failing an assertion about "%PDF", both of which read as a PDF
# bug. About two seconds on a fresh bundle, instant afterwards. A missing
# binary is not this file's problem to report: the PDF tests say so themselves.
unless ENV["SKIP_WKHTMLTOPDF_WARMUP"]
  begin
    system(Gem.bin_path("wkhtmltopdf-binary", "wkhtmltopdf"), "--version", out: File::NULL, err: File::NULL)
  rescue Gem::Exception, Errno::ENOENT
    nil
  end
end

# Scratch the suites leave behind. tmp/storage is the :test Active Storage
# root (config/storage.yml) and nothing prunes it — about 18 MB per three hours
# of gate runs; tmp/capybara keeps every failure screenshot, so a stale one
# from an earlier run reads as evidence for this one. Emptied in the parent
# because a wipe from inside a test deletes a sibling worker's blobs mid-run
# (test/lib/object_storage_migrator_test.rb learnt that). Deliberately NOT
# tmp/* — tmp/screenshots holds the mockups a session attaches to Trello cards
# after a push — and not the per-worker storage/test.sqlite3_N files. Two
# suites running at once in ONE checkout would wipe each other; the gate runs
# them one after the other.
unless ENV["KEEP_TEST_STORAGE"]
  %w[tmp/storage tmp/storage_bucket tmp/capybara].each do |dir|
    FileUtils.rm_rf(Dir[Rails.root.join(dir, "*").to_s])
  end
end

# Free-text moderation holds every typed answer out of `responses.answers`
# until it is screened (app/lib/moderation.rb). Hundreds of older tests post a
# free-text answer and assert the text they read back, so the hold is OFF for
# the suite by default; the moderation tests switch it on for themselves (see
# ModerationTestHelper). The scrub still runs — it has no switch.
Moderation.hold_enabled = false

class ActiveSupport::TestCase
  # One forked worker per core, each with its own SQLite file — and, under
  # test:system, its own Puma and Chrome. Measured 2026-09-12 on 4 cores:
  # `rails test` 224s -> 71s, `rails test:system` ~20 min -> ~8.6 min, green.
  # PARALLEL_WORKERS overrides this. Never set it ABOVE the core count: 6
  # workers on 4 cores ran faster still and flaked three browser timings.
  # PARALLEL_WORKERS=1 is the old serial run, for bisecting a suspected
  # cross-test interaction.
  parallelize(workers: :number_of_processors)

  # Run the block with the moderation hold on, as it is in production.
  def with_moderation_hold
    previous = Moderation.hold_enabled
    Moderation.hold_enabled = true
    yield
  ensure
    Moderation.hold_enabled = previous
  end

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

  # Performs enqueued jobs INCLUDING jobs that performed jobs enqueue —
  # bare perform_enqueued_jobs only flushes what was queued when it was
  # called, so a self-chaining job (Comms::SendCampaignBatchJob) needs the
  # loop.
  def drain_enqueued_jobs
    perform_enqueued_jobs while enqueued_jobs.any?
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
