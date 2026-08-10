# Builds one Verto's Ask Verto index.
#
# Enqueued when staff approve a Verto, and again by the nightly refresh so a Verto
# that keeps collecting doesn't answer from the numbers it had on approval day.
#
# It runs one Verto at a time on purpose. Solid Queue runs inside Puma on a small
# instance, and aggregating every response of every contributed Verto in one job
# is exactly the memory shape the watchdog restarts the process for. CorpusIndexer
# aggregates through the existing batched select(:id, :answers) path, so one Verto
# is never fully resident either.
class IndexCorpusEntryJob < ApplicationJob
  queue_as :default

  # No retries. A re-index that fails leaves the previous index in place, which is
  # stale but correct and still consented — far better than a retry storm billing
  # the account for repeated theming calls. The next nightly run picks it up.
  discard_on StandardError do |job, error|
    ErrorReporting.report("IndexCorpusEntryJob", error, corpus_entry_id: job.arguments.first)
  end

  def perform(corpus_entry_id)
    entry = CorpusEntry.find_by(id: corpus_entry_id)
    return unless entry
    # Consent is re-checked HERE, not only at enqueue time. A creator can withdraw
    # between the two, and indexing a withdrawn Verto would write rows that the
    # read-time filter then has to hide — correct, but it means holding data we
    # were asked to stop using.
    return unless entry.citable?

    CorpusIndexer.new(entry).call
  end

  # Re-index everything currently citable. Called by the recurring task; enqueues
  # one job per Verto rather than doing the work here, so no single job holds more
  # than one Verto's aggregation.
  def self.refresh_all!
    CorpusEntry.citable.pluck(:id).each { |id| perform_later(id) }
  end
end
