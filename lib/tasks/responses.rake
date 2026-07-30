# Retention enforcement for respondent data (P0-7). See docs/DATA_RETENTION.md.
#
# Deliberately NOT scheduled. How long to keep research data is the customer's
# policy decision, not ours, and a recurring job that silently deleted a
# funder's dataset would be far worse than one that never ran. Wire it into
# config/recurring.yml once a retention period has actually been agreed.
namespace :responses do
  desc "Delete responses older than N days (responses:purge[365] or responses:purge[365,dry])"
  task :purge, [ :days, :mode ] => :environment do |_t, args|
    days = args[:days].to_i
    if days <= 0
      abort "Usage: bin/rails responses:purge[DAYS]   (DAYS must be a positive integer)"
    end

    dry    = args[:mode].to_s.downcase.start_with?("dry")
    cutoff = days.days.ago
    scope  = Response.where(created_at: ...cutoff)
    count  = scope.count

    puts "Responses created before #{cutoff.utc.iso8601}: #{count}"

    if count.zero?
      puts "Nothing to purge."
      next
    end

    if dry
      puts "Dry run — nothing deleted."
      next
    end

    # destroy_all rather than delete_all: Response has after_commit callbacks
    # (the live-results broadcast), and skipping them would leave the results
    # screens of anyone watching showing a count that no longer exists.
    deleted = scope.destroy_all.size
    puts "Purged #{deleted} response(s)."
    puts "Cached summaries and reports keyed to the old response counts will regenerate on next view."
  end
end
