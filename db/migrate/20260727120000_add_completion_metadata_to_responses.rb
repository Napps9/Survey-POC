class AddCompletionMetadataToResponses < ActiveRecord::Migration[8.1]
  def change
    # How long a respondent took, and on what kind of device. Duration stays
    # derived from these two timestamps rather than stored as a third column, so
    # there's one source of truth (see Response#duration_seconds).
    #
    # device_kind holds a coarse bucket — "phone"/"tablet"/"desktop" — never the
    # raw User-Agent. A full UA string is a fingerprinting vector, and this app
    # is deliberate about not collecting that class of data elsewhere: region is
    # self-declared rather than IP-inferred, and the request IP is used for
    # rate-limiting but never persisted.
    add_column :responses, :started_at,   :datetime
    add_column :responses, :completed_at, :datetime
    add_column :responses, :device_kind,  :string
  end
end
