namespace :upgrade do
  desc "Promote legacy multiple_choice / select_many cards to image-grid when their options fit"
  task choice_cards: :environment do
    promoted = 0
    skipped  = 0

    Survey.find_each do |survey|
      changed = false
      new_cards = Array(survey.cards).map do |card|
        type = card["type"]
        next card unless %w[multiple_choice select_many].include?(type)

        opts = Array(card["options"])
        fits_grid = opts.size <= 10 && opts.all? { |o| o.to_s.length <= 14 }

        unless fits_grid
          skipped += 1
          next card
        end

        promoted += 1
        changed  = true
        new_type = type == "select_many" ? "select_many_grid" : "select_one_grid"
        card.merge("type" => new_type)
      end

      survey.update_column(:cards, new_cards) if changed
    end

    puts "Promoted #{promoted} card(s) to image-grid. " \
         "Left #{skipped} card(s) as image-list (long labels or >10 options)."
  end
end
