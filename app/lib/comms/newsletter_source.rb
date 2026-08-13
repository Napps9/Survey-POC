# What went into this week's newsletter, and what to say when nothing else
# can be said. Pure functions over already-fetched commit hashes — no network,
# no Claude, no Active Record — so the judgement calls here (what counts as a
# shippable change, how an edition reads when the writer is unavailable) are
# testable without stubbing anything.
module Comms
  module NewsletterSource
    module_function

    # A week's worth of commits is small; the cap is a cost bound on the
    # prompt, not a real limit.
    MAX_COMMITS      = 40
    MAX_BODY_CHARS   = 600
    MAX_SUBJECT_CHARS = 160

    # Commits that describe plumbing rather than a change a customer could
    # notice. Merges carry no content of their own, and the rest are the
    # repo's recurring housekeeping.
    SKIP_SUBJECT = /\A(merge |revert |bump |wip\b|fixup!|squash!)/i

    # Trailers the repo appends to every commit — signature, not content.
    TRAILER = /^(Co-Authored-By|Claude-Session|Signed-off-by|Generated with):/i

    # The Monday of the week a run belongs to. The edition generated on
    # Thursday and sent the following Monday is stamped with the Monday of
    # the week the WORK happened in, so the stamp reads the same however
    # late a re-run happens.
    def week_of(date)
      d = date.to_date
      d - ((d.wday + 6) % 7)
    end

    # The Monday after the run — when the owner approves it for.
    def next_monday(date)
      week_of(date) + 7
    end

    # Raw GitHub commit hashes -> the shippable ones, newest first, deduped
    # by message so a rebase or a cherry-pick doesn't say the same thing
    # twice.
    def digest(raw)
      seen = {}

      Array(raw).each do |c|
        message = c.is_a?(Hash) ? c.dig("commit", "message").to_s : ""
        next if message.blank?

        subject, body = split_message(message)
        next if subject.blank? || subject.match?(SKIP_SUBJECT)

        key = subject.downcase
        next if seen.key?(key)

        seen[key] = {
          "subject" => subject.truncate(MAX_SUBJECT_CHARS),
          "body"    => body.truncate(MAX_BODY_CHARS),
          "sha"     => c["sha"].to_s.first(7),
          "date"    => c.dig("commit", "author", "date").to_s
        }
      end

      seen.values.first(MAX_COMMITS)
    end

    # The edition that goes out when Claude can't write it — no key, a failed
    # call, a shape we don't trust. Commit subjects in this repo are written
    # as evocative one-liners, so they read as headlines already; the bodies
    # are left out because they are addressed to the next developer, not to a
    # customer. The owner edits this before Monday, same as any other draft.
    def fallback_copy(commits, week)
      items = Array(commits).first(6).map do |c|
        { "title" => c["subject"].to_s, "body" => "" }
      end

      {
        "subject"   => "What's new in VertoNow — week of #{week.strftime("%-d %B")}",
        "preheader" => "A short note on what changed this week.",
        "intro"     => "Here's what we've been building this week. As always, " \
                       "tell us what you'd like to see next — it genuinely shapes what we do.",
        "items"     => items,
        "cta_label" => "Open VertoNow",
        "sign_off"  => "Thanks for being here early.",
        "source"    => "fallback"
      }
    end

    def split_message(message)
      lines = message.to_s.split("\n")
      subject = lines.first.to_s.strip
      body = lines.drop(1).reject { |l| l.match?(TRAILER) }.join("\n").strip
      [ subject, body ]
    end
  end
end
