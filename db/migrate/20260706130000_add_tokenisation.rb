class AddTokenisation < ActiveRecord::Migration[8.1]
  def change
    # A Verto has tokenisation on when this is true: cards may carry a
    # `tokens` (per-option) or `token_award` (flat) key in the cards JSON, and
    # players earn points as they answer. Mirrors how `quiz` gates `correct`.
    add_column :surveys, :tokenisation_enabled, :boolean, default: false, null: false

    # The token types this Verto awards, e.g. [{"id"=>"gold","name"=>"Gold
    # Coins","icon"=>"🪙"}]. Cards reference a type by its stable `id`, so
    # renaming a type never breaks existing card config.
    add_column :surveys, :token_types, :json, default: [], null: false

    # Server-computed running totals cached on the response, keyed by token
    # type id: {"gold"=>12,"coal"=>3}. Empty on non-tokenised responses.
    # Cached (rather than recomputed) so "compare your tokens" is a cheap read.
    add_column :responses, :token_totals, :json, default: {}, null: false
  end
end
