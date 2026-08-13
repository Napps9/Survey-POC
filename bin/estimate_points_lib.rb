# frozen_string_literal: true

# Library code for the automated Fibonacci story-point estimator. See
# bin/estimate_points for the CLI wrapper and bin/trello_log for how this
# gets invoked automatically when a card is logged without --points.
#
# Deliberately Rails-free (plain Ruby + net/http), same as trello_log itself:
# it needs to run fast, at the tail end of a push, without a framework boot.

require "net/http"
require "uri"
require "json"
require "open3"
require "time"
require "fileutils"
require_relative "trello_client"
require_relative "claude_client"

module StoryPointEstimator
  FIB_SEQUENCE = [ 1, 2, 3, 5, 8, 13 ].freeze

  # Sum of the 4 axis scores (0-3 each, so 0-12 total) -> Fibonacci points.
  # Keeping this as a plain lookup (not model-computed) means the mapping
  # can never drift from policy regardless of what the model returns.
  SUM_TO_POINTS = {
    (0..1)   => 1,
    (2..3)   => 2,
    (4..5)   => 3,
    (6..7)   => 5,
    (8..9)   => 8,
    (10..12) => 13
  }.freeze

  # NOT under log/ — Rails' default .gitignore excludes /log/* entirely, and
  # this file is meant to accumulate as real, committed history (raw
  # material for future few-shot examples), not be treated as a disposable
  # runtime log. Kept at the repo root so it's easy to find and diff.
  DEFAULT_LOG_PATH = ENV.fetch("POINTS_ESTIMATOR_LOG", File.expand_path("../points_estimator_log.jsonl", __dir__))

  # ─────────────────────────────────────────────────────────────
  # Stage 1: deterministic diff-stat extraction
  # ─────────────────────────────────────────────────────────────

  module DiffStats
    # Rails migration convention: db/migrate/<timestamp>_<name>.rb
    MIGRATION_PATTERN = %r{\Adb/migrate/\d+_.*\.rb\z}
    # This repo's Minitest convention: test/**/*_test.rb (see test/ tree).
    TEST_PATTERN = %r{(?:\A|/)test/.*_test\.rb\z}

    ModuleOf = lambda do |path|
      parts = path.split("/")
      # Nest one level deeper for the directories that actually carry
      # meaningfully distinct modules (app/javascript vs app/views vs
      # app/controllers are very different kinds of change); everything
      # else just uses its top-level directory. Only nest when parts[1] is
      # itself a subdirectory (parts.length > 2) — a bare file directly
      # under config/ (e.g. config/importmap.rb) has no third segment, so
      # nesting would just reproduce the filename as a fake "module".
      if %w[app config test].include?(parts[0]) && parts.length > 2
        "#{parts[0]}/#{parts[1]}"
      else
        parts[0]
      end
    end

    def self.git_numstat(base_ref, head_ref)
      # base_ref/head_ref as two separate argv entries, not one interpolated
      # "a..b" string — Open3's array form never shells out (no metachar
      # risk either way), but this also avoids relying on git's own parsing
      # of a hand-built range expression for two refs that came from a CLI
      # flag.
      out, err, status = Open3.capture3("git", "diff", "--numstat", base_ref, head_ref)
      raise "git diff --numstat failed: #{err}" unless status.success?

      out = out.force_encoding("UTF-8").scrub
      out.each_line.filter_map do |line|
        added, removed, path = line.chomp.split("\t", 3)
        next nil if path.nil?

        # Binary files report "-" for both counts.
        { path: path, added: (added == "-" ? 0 : added.to_i), removed: (removed == "-" ? 0 : removed.to_i) }
      end
    end

    # Returns the plain `git diff` text for the same range, for stage 3 to
    # hand to the model alongside the stats (not stats-only — see the
    # rationale in the system prompt below).
    def self.git_diff_content(base_ref, head_ref, max_bytes: 60_000)
      out, err, status = Open3.capture3("git", "diff", base_ref, head_ref)
      raise "git diff failed: #{err}" unless status.success?

      # Open3 tags the pipe's bytes with the external encoding (often
      # US-ASCII in a minimal shell env) even though this repo's source
      # comments are full of UTF-8 punctuation (em dashes, arrows, curly
      # quotes) — force + scrub before it's ever concatenated into a UTF-8
      # prompt string, or Ruby raises Encoding::CompatibilityError.
      out = out.force_encoding("UTF-8").scrub
      return out if out.bytesize <= max_bytes

      # byteslice can land mid-character on a multi-byte UTF-8 sequence;
      # scrub again to repair the cut boundary rather than ship it broken.
      "#{out.byteslice(0, max_bytes).scrub}\n\n… [diff truncated at #{max_bytes} bytes]"
    end

    def self.extract(base_ref, head_ref = "HEAD")
      files = git_numstat(base_ref, head_ref)
      modules = files.map { |f| ModuleOf.call(f[:path]) }.uniq.sort
      test_files = files.count { |f| f[:path].match?(TEST_PATTERN) }

      {
        "base_ref"        => base_ref,
        "head_ref"        => head_ref,
        "files_changed"   => files.size,
        "lines_added"     => files.sum { |f| f[:added] },
        "lines_removed"   => files.sum { |f| f[:removed] },
        "lines_changed"   => files.sum { |f| f[:added] + f[:removed] },
        "test_file_count" => test_files,
        "test_file_ratio" => files.empty? ? 0.0 : (test_files.to_f / files.size).round(3),
        "migration_present" => files.any? { |f| f[:path].match?(MIGRATION_PATTERN) },
        "modules_touched" => modules,
        "module_count"    => modules.size,
        "files"           => files.map { |f| { "path" => f[:path], "added" => f[:added], "removed" => f[:removed] } }
      }
    end
  end

  # ─────────────────────────────────────────────────────────────
  # Stage 2: cheap pre-filter — skip the LLM entirely for trivially small diffs
  # ─────────────────────────────────────────────────────────────

  def self.trivial?(stats)
    stats["files_changed"] == 1 &&
      stats["lines_changed"] < 20 &&
      !stats["migration_present"] &&
      stats["test_file_count"].zero?
  end

  # ─────────────────────────────────────────────────────────────
  # Stage 3: LLM scoring (Claude, forced tool-use, temperature > 0)
  # ─────────────────────────────────────────────────────────────

  module Scoring
    DEFAULT_MODEL       = ClaudeClient::DEFAULT_MODEL
    # Nonzero on purpose — see self_consistency below. Sampling at temp 0
    # three times mostly just returns the same answer three times and burns
    # 3x the cost for near-zero extra signal; real self-consistency needs
    # actual diversity across runs to have anything to vote on.
    DEFAULT_TEMPERATURE = Float(ENV.fetch("POINTS_ESTIMATOR_TEMPERATURE", "0.8"))
    MAX_TOKENS = 700

    AXES = %w[blast_radius verification ambiguity risk].freeze

    RUBRIC = <<~RUBRIC
      Score the diff on 4 independent axes, each 0-3. Read the actual diff content
      below, not just the stats — the stats can't tell you whether 41 changed files
      are 41 independent risky decisions or the same one-line fix copy-pasted into
      40 near-identical files (e.g. a locale string propagated to every translation
      file). Weigh what the lines actually do.

      ## blast_radius (0-3) — how much of the app is affected
        0 — a single, isolated code path with no cross-cutting effect (an internal
            helper, a comment, dead-code cleanup).
        1 — affects one feature/screen for one class of user.
        2 — affects multiple related screens/flows, or a shared component used by
            a handful of callers.
        3 — affects a widely-shared component/data model touched by many
            independent features, or every user session (auth, the core editor,
            billing, the primary navigation).

      ## verification (0-3) — how hard it is to trust this is correct
        0 — self-evidently correct from reading the diff (a copy/string change,
            a comment, a config value with no behavioral branch).
        1 — existing automated tests cover it, or it's simple enough that a quick
            manual check suffices.
        2 — needs new/updated test coverage and/or a manual walkthrough of a real
            flow to be confident.
        3 — requires end-to-end verification across multiple flows/roles/browsers,
            and/or the automated suite doesn't meaningfully cover the change (e.g.
            client-side interaction behavior in a codebase whose test suite is
            server-side integration tests only).

      ## ambiguity (0-3) — how much judgment the change required
        0 — mechanical: a fixed pattern applied verbatim (e.g. copying an existing
            fix to a sibling file that has the identical bug).
        1 — a few small decisions with an obvious best answer.
        2 — real design tradeoffs were made (choosing between reasonable
            architectures, inventing a new pattern).
        3 — high uncertainty: the right fix wasn't obvious going in, required
            exploration, or reasonable engineers could disagree on the approach.

      ## risk (0-3) — how bad and how hard to undo if this is wrong
        0 — trivially revertible, no user-facing or data effect if wrong (internal
            script, dev-only tooling).
        1 — revertible with a follow-up deploy; user-facing but low-stakes if
            briefly wrong.
        2 — meaningful but recoverable impact if wrong (bad UX, a support ticket),
            or touches persisted data in a reversible way.
        3 — hard or impossible to cleanly undo (irreversible data migration,
            security/financial-sensitive, or breaks a critical path for every
            user — auth, payment, the core editor).

      Score each axis independently — a change can be high blast_radius but low
      ambiguity (a mechanical fix copied to every call site of a widely-used
      component), or high ambiguity but low blast_radius (a genuinely hard design
      decision confined to one internal script nobody else depends on).
    RUBRIC

    # ── Few-shot calibration examples ──────────────────────────────────
    # Each entry is [diff-stats JSON] -> [axis scores] -> [final points], as
    # requested. ALL of these are placeholders except the first, which is a
    # FORMAT TEMPLATE ONLY (marked below) so the prompt is syntactically
    # complete even before real examples are filled in — it is not
    # calibrated data and should not be trusted for real scoring decisions.
    #
    # Replace every entry marked PLACEHOLDER with a real (stats, axes, points)
    # triple pulled from this board's actual history — pick ones that anchor
    # the boundaries you care about (e.g. one clear 1, one clear 13, and a
    # couple of borderline cases where two adjacent values both felt
    # plausible). log/points_estimator.jsonl accumulates real runs over time
    # specifically so you have raw material to mine these from.
    FEWSHOT_EXAMPLES = [
      {
        label: "FORMAT TEMPLATE ONLY — not calibrated, do not use as a real anchor",
        stats: {
          files_changed: 1, lines_changed: 8, test_file_count: 0,
          migration_present: false, modules_touched: [ "bin" ]
        },
        diff_summary: "One-line fix: route an HTTP client through an env-configured proxy that was previously ignored.",
        axes: { blast_radius: 0, verification: 1, ambiguity: 0, risk: 0 },
        points: 1
      },
      { label: "PLACEHOLDER 1 — replace with a real small/medium example from your board", placeholder: true },
      { label: "PLACEHOLDER 2 — replace with a real example", placeholder: true },
      { label: "PLACEHOLDER 3 — replace with a real example", placeholder: true },
      { label: "PLACEHOLDER 4 — replace with a real example", placeholder: true },
      { label: "PLACEHOLDER 5 — replace with a real large/risky example from your board", placeholder: true }
    ].freeze

    def self.fewshot_block
      FEWSHOT_EXAMPLES.map.with_index(1) do |ex, i|
        if ex[:placeholder]
          "### Example #{i} (#{ex[:label]})\n[not yet filled in]"
        else
          <<~EX
            ### Example #{i} (#{ex[:label]})
            Diff stats: #{JSON.generate(ex[:stats])}
            What the diff does: #{ex[:diff_summary]}
            Axis scores: #{JSON.generate(ex[:axes])} (sum=#{ex[:axes].values.sum})
            Final points: #{ex[:points]}
          EX
        end
      end.join("\n")
    end

    def self.system_prompt
      placeholders_remaining = FEWSHOT_EXAMPLES.count { |ex| ex[:placeholder] }
      warning = placeholders_remaining.positive? ? "\n\n(Note: #{placeholders_remaining} of the few-shot examples below are unfilled placeholders — score using the rubric itself, the filled examples are too few to lean on heavily yet.)" : ""

      <<~SYSTEM
        You size code changes for Fibonacci story-point estimation on a Trello
        board, using a fixed rubric so scoring stays consistent across runs and
        across time. #{RUBRIC}

        ## Calibration examples#{warning}

        #{fewshot_block}

        Now score the diff you're given. Read the actual diff content, cite
        specific files/lines in your summary, and output via the emit_axis_scores
        tool. Output the axis scores — they are what you're being asked to
        reason about; do not attempt to compute or state a final point value
        yourself, that mapping is applied deterministically outside your response.
      SYSTEM
    end

    TOOL = {
      name: "emit_axis_scores",
      description: "Score this diff on the 4 rubric axes and explain which one dominates the sizing.",
      input_schema: {
        type: "object",
        properties: {
          blast_radius: { type: "integer", enum: [ 0, 1, 2, 3 ], description: "0-3 per the blast_radius rubric." },
          verification: { type: "integer", enum: [ 0, 1, 2, 3 ], description: "0-3 per the verification rubric." },
          ambiguity:    { type: "integer", enum: [ 0, 1, 2, 3 ], description: "0-3 per the ambiguity rubric." },
          risk:         { type: "integer", enum: [ 0, 1, 2, 3 ], description: "0-3 per the risk rubric." },
          dominant_axis: {
            type: "string", enum: AXES,
            description: "Which single axis most drove the overall sizing."
          },
          summary: {
            type: "string",
            description: "1-3 sentences justifying the scores, citing specific files or changes from the diff."
          }
        },
        required: AXES + %w[dominant_axis summary]
      }
    }.freeze

    def self.build_user_message(stats, diff_content)
      <<~MSG
        Diff stats (deterministic, computed from git — trust these numbers, but
        they can't tell you WHAT changed, only how much surface area):
        #{JSON.pretty_generate(stats.reject { |k, _| k == "files" })}

        Files touched:
        #{JSON.pretty_generate(stats["files"])}

        Full diff content:
        ```diff
        #{diff_content}
        ```
      MSG
    end

    def self.call_claude(system:, user_message:, api_key:, model:, temperature:)
      ClaudeClient.messages(
        api_key: api_key, model: model, max_tokens: MAX_TOKENS,
        system: system, user_message: user_message, temperature: temperature,
        tools: [ TOOL ], tool_choice: { type: "tool", name: TOOL[:name] }
      )
    end

    def self.points_for_sum(sum)
      entry = SUM_TO_POINTS.find { |range, _| range.cover?(sum) }
      raise "Axis sum #{sum} outside the expected 0-12 range" unless entry

      entry[1]
    end

    # One scoring attempt: one Claude call -> validated axis scores -> a
    # deterministically-computed sum/points (never trusting the model's own
    # arithmetic, even though we ask it to reason axis-by-axis first).
    def self.score_attempt(stats, diff_content, api_key:, model: DEFAULT_MODEL, temperature: DEFAULT_TEMPERATURE)
      response = call_claude(
        system: system_prompt,
        user_message: build_user_message(stats, diff_content),
        api_key: api_key, model: model, temperature: temperature
      )
      block = Array(response["content"]).find { |b| b["type"] == "tool_use" }
      raise "Model did not return a tool_use block: #{response.inspect}" unless block

      input = block["input"]
      AXES.each do |axis|
        val = input[axis]
        raise "Invalid #{axis} score from model: #{val.inspect}" unless val.is_a?(Integer) && (0..3).cover?(val)
      end

      sum = AXES.sum { |a| input[a] }
      {
        "blast_radius"  => input["blast_radius"],
        "verification"  => input["verification"],
        "ambiguity"     => input["ambiguity"],
        "risk"          => input["risk"],
        "sum"           => sum,
        "points"        => points_for_sum(sum),
        "dominant_axis" => input["dominant_axis"],
        "summary"       => input["summary"],
        "model"         => model,
        "temperature"   => temperature
      }
    end

    def self.score_three_times(stats, diff_content, api_key:, model: DEFAULT_MODEL, temperature: DEFAULT_TEMPERATURE)
      3.times.map { score_attempt(stats, diff_content, api_key: api_key, model: model, temperature: temperature) }
    end
  end

  # ─────────────────────────────────────────────────────────────
  # Stage 4: self-consistency across the 3 scoring attempts
  # ─────────────────────────────────────────────────────────────

  # status:
  #   "auto"        — all 3 attempts agreed; that value is authoritative.
  #   "auto_median" — attempts spanned exactly 1 Fibonacci step; the median
  #                   (by sequence position, not numeric value) is used.
  #   "flagged"     — attempts spanned more than 1 step; do NOT auto-write a
  #                   points value, surface all 3 attempts for manual review.
  def self.self_consistency(attempts)
    points_list = attempts.map { |a| a["points"] }
    indices = points_list.map { |p| FIB_SEQUENCE.index(p) }
    spread = indices.max - indices.min

    status, points =
      if spread.zero?
        [ "auto", points_list.first ]
      elsif spread == 1
        [ "auto_median", points_list.sort_by { |p| FIB_SEQUENCE.index(p) }[1] ]
      else
        [ "flagged", nil ]
      end

    { "status" => status, "points" => points, "disagreement_steps" => spread, "attempts" => attempts }
  end

  # ─────────────────────────────────────────────────────────────
  # Stage 5: Trello write — points label + an always-posted audit comment
  # ─────────────────────────────────────────────────────────────

  module TrelloWrite
    def self.comment_for(result, method:)
      case method
      when "trivial_prefilter"
        <<~TXT
          **Story points: 1** (auto — deterministic pre-filter)

          Single file, < 20 lines changed, no migration, no test files touched.
          Skipped the LLM scoring call entirely — this size/shape is unambiguously
          a 1 by policy, not a judgment call.
        TXT
      else
        attempts = result["attempts"]
        lines = attempts.each_with_index.map do |a, i|
          "Attempt #{i + 1}: blast_radius=#{a['blast_radius']} verification=#{a['verification']} " \
          "ambiguity=#{a['ambiguity']} risk=#{a['risk']} (sum=#{a['sum']}) -> **#{a['points']}** " \
          "[dominant: #{a['dominant_axis']}]\n#{a['summary']}"
        end.join("\n\n")

        if result["status"] == "flagged"
          <<~TXT
            **Story points: NOT auto-assigned — flagged for manual review**

            The 3 scoring attempts disagreed by #{result['disagreement_steps']} Fibonacci
            step(s), more than the 1-step tolerance for an automatic median. Please pick
            a value by hand and add the label yourself.

            #{lines}
          TXT
        else
          label = result["status"] == "auto_median" ? "median of a 1-step split" : "all 3 attempts agreed"
          <<~TXT
            **Story points: #{result['points']}** (auto — #{label})

            #{lines}
          TXT
        end
      end
    end

    def self.apply(card_id:, result:, method:, auth:, dry_run:)
      text = comment_for(result, method: method)

      if dry_run
        return { "label_written" => false, "comment_posted" => false, "dry_run" => true, "comment_text" => text }
      end

      TrelloClient.comment(card_id, text, auth)
      label_written = false
      if result["points"]
        TrelloClient.add_points_label(card_id, result["points"].to_s, auth)
        label_written = true
      end
      { "label_written" => label_written, "comment_posted" => true, "dry_run" => false }
    end
  end

  # ─────────────────────────────────────────────────────────────
  # Stage 6: local log for building future few-shot examples
  # ─────────────────────────────────────────────────────────────

  def self.append_log(entry, log_path: DEFAULT_LOG_PATH)
    FileUtils.mkdir_p(File.dirname(log_path))
    File.open(log_path, "a") { |f| f.puts(JSON.generate(entry)) }
  rescue => e
    warn "[estimate_points] Failed to write local log at #{log_path}: #{e.class}: #{e.message}"
  end

  # ─────────────────────────────────────────────────────────────
  # Orchestration — ties stages 1-6 together for bin/trello_log to call
  # ─────────────────────────────────────────────────────────────

  # commit_ref: the resolved HEAD sha at estimate time, for the log's audit
  # trail — passed separately from head_ref since head_ref might be a
  # branch name that keeps moving.
  def self.run(base_ref:, card_id:, auth:, head_ref: "HEAD", api_key: ENV["ANTHROPIC_API_KEY"],
                log_path: DEFAULT_LOG_PATH, dry_run: false)
    stats = DiffStats.extract(base_ref, head_ref)
    # Open3, not backticks — backticks always shell out (`sh -c "..."`), so
    # a head_ref containing shell metacharacters would execute arbitrarily.
    rev_out, _err, rev_status = Open3.capture3("git", "rev-parse", head_ref)
    commit_sha = rev_status.success? ? rev_out.strip : head_ref
    timestamp = Time.now.utc.iso8601

    if trivial?(stats)
      result = { "status" => "auto", "points" => 1, "disagreement_steps" => 0, "attempts" => [] }
      method = "trivial_prefilter"
    else
      raise "ANTHROPIC_API_KEY is required to score a non-trivial diff" if api_key.to_s.empty?

      diff_content = DiffStats.git_diff_content(base_ref, head_ref)
      attempts = Scoring.score_three_times(stats, diff_content, api_key: api_key)
      result = self_consistency(attempts)
      method = "llm_self_consistency"
    end

    write_result = TrelloWrite.apply(card_id: card_id, result: result, method: method, auth: auth, dry_run: dry_run)

    log_entry = {
      "timestamp"   => timestamp,
      "commit"      => commit_sha,
      "base_ref"    => base_ref,
      "card_id"     => card_id,
      "method"      => method,
      "stats"       => stats,
      "result"      => result,
      "write"       => write_result
    }
    append_log(log_entry, log_path: log_path) unless dry_run

    { "stats" => stats, "result" => result, "method" => method, "write" => write_result, "log_entry" => log_entry }
  end
end
