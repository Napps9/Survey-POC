class AddFlowsToSurveys < ActiveRecord::Migration[8.1]
  # First-class named flows for answer-branching: a flow is a named, coloured
  # group of cards (membership rides on each card as `flow_id` inside the cards
  # JSON) that a routed answer can enter — e.g. UK / UAE / USA regional question
  # sets. This column holds only the flow metadata (id, name, colour, exit);
  # FlowCompiler compiles it down to the per-card `next` pointers the player
  # already resolves, so play-time semantics are unchanged and no backfill is
  # needed — decks without flows round-trip untouched.
  def change
    add_column :surveys, :flows, :json, default: [], null: false
  end
end
