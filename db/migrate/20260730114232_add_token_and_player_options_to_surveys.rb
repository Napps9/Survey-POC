# Tokenisation and end-screen options that were previously hardcoded.
#
# The two _enabled defaults differ on purpose. Share and Compare-regions are on
# for every published Verto today, so defaulting them to false would silently
# remove a live feature from every existing Verto — they default true and the
# new setting only lets a creator turn them OFF. The two token behaviours are
# new, so they default false and nothing changes until a creator opts in; that
# matters most for token_back_nav_enabled, which alters what a respondent can
# go back and change.
class AddTokenAndPlayerOptionsToSurveys < ActiveRecord::Migration[8.1]
  def change
    # Which card carries the "you'll earn points" intro. nil = the welcome card,
    # which is where it was hardcoded. Stores a cid, not an index, so the intro
    # follows its card when the deck is reordered.
    add_column :surveys, :token_intro_cid, :string

    # Show each answer's own token award as the respondent leaves the card,
    # rather than only ever a running total.
    add_column :surveys, :token_reveal_enabled, :boolean, default: false, null: false

    # Let a respondent go back and answer a tokenised card they skipped. The
    # server has always allowed this (PlayerController#locked_merge keys off
    # whether an answer was actually stored); the player was stricter.
    add_column :surveys, :token_back_nav_enabled, :boolean, default: false, null: false

    add_column :surveys, :share_enabled, :boolean, default: true, null: false
    add_column :surveys, :regions_enabled, :boolean, default: true, null: false
  end
end
