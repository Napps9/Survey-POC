namespace :demographics do
  desc "Backfill demographic_gender / demographic_birth_year from stored answers (DRY_RUN=1 to preview)"
  # New responses denormalise these on save; this fills in the ones stored
  # before the columns existed, so the demographic filters aren't blank on every
  # Verto that already has responses.
  task backfill: :environment do
    dry_run = ENV["DRY_RUN"].present?
    filled  = scanned = 0

    Survey.where.not(cards: nil).find_each(batch_size: 25) do |survey|
      cards      = Array(survey.cards)
      # Keyless-or-"gender" guard mirrors PlayerController#sync_demographics_from_answers! —
      # the opt-in Heritage card is also a demographic multiple_choice and must
      # not steal the gender slot.
      gender_idx = cards.find_index do |c|
        next false unless c.is_a?(Hash) && c["demographic"] && c["type"] == "multiple_choice"
        key = c["demographic_key"].to_s
        key.empty? || key == "gender"
      end
      birth_idx  = cards.find_index { |c| c.is_a?(Hash) && c["demographic"] && c["input"] == "month" }
      next if gender_idx.nil? && birth_idx.nil?

      allowed = gender_idx ? Array(cards[gender_idx]["options"]).map(&:to_s) : []

      survey.responses.where(demographic_gender: nil, demographic_birth_year: nil)
            .select(:id, :answers).find_each(batch_size: 500) do |response|
        scanned += 1
        answers = response.answers.is_a?(Hash) ? response.answers : {}

        gender = gender_idx ? answers[gender_idx.to_s]&.dig("value").to_s.strip.presence : nil
        gender = nil unless allowed.include?(gender)

        year = birth_idx ? answers[birth_idx.to_s]&.dig("value").to_s[/\A(\d{4})/, 1]&.to_i : nil
        year = nil unless year && year.between?(1900, Date.current.year)

        next if gender.nil? && year.nil?

        filled += 1
        next if dry_run

        # update_columns: these are derived values, and a touched updated_at on
        # every historical response would look like a wave of new activity.
        Response.where(id: response.id)
                .update_all(demographic_gender: gender, demographic_birth_year: year)
      end
    end

    puts "#{dry_run ? '[DRY RUN] ' : ''}responses scanned: #{scanned}"
    puts "responses with demographics filled in: #{filled}"
  end
end
