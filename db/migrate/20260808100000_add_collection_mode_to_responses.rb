# How a response was collected, when that isn't simply "on the web".
#
# The WLL Transforming Education programme ran the same Verto twice — once
# digitally and once on paper, transcribed afterwards — and the two are one
# study, not two. Merging them into a single Verto is what lets Ask Verto cite
# "n = 54,000" rather than two unrelated-looking surveys; keeping the mode is
# what lets it answer "did the paper cohort say something different?".
#
# A column rather than a reused one, deliberately:
#
#   device_kind is derived from the user agent (see app/lib/device_kind.rb) and
#   has its own vocabulary; writing "paper" into it would break every reader
#   that trusts that vocabulary.
#
#   survey_share_id distinguishes PARTNER ORGANISATIONS, and the corpus
#   deliberately never publishes share segments — a partner's slice is their
#   business, not the corpus's.
#
# NULL means the ordinary case: collected through the player, on the web. Only
# an import that knows otherwise sets it, so nothing already stored changes
# meaning. Deliberately unconstrained: the next programme may collect by SMS,
# kiosk or phone, and a CHECK listing today's two modes would have to be
# migrated before it could say so.
class AddCollectionModeToResponses < ActiveRecord::Migration[8.1]
  def change
    add_column :responses, :collection_mode, :string

    # The corpus indexer groups by this per survey to build the breakdown, and
    # skips it entirely when every response is NULL.
    add_index :responses, [ :survey_id, :collection_mode ],
              name: "index_responses_on_survey_and_collection_mode"
  end
end
