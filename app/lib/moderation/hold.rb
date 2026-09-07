# Lifts free text out of a response's answers on the way to the database.
#
# Two calls, either side of `resp.save!`:
#
#   items = Moderation::Hold.extract!(resp, survey)   # rewrites resp.answers
#   resp.save!
#   Moderation::Hold.persist!(resp, items)             # writes the HeldText rows
#
# extract! scrubs every free-text slot (Moderation::Scrub), then for each one
# decides between three outcomes by looking the text up among the response's
# existing rows:
#
#   no row, or a superseded one   → hold it: the slot becomes nil, the marker
#                                   says "held", and an item is returned for
#                                   persist! to write once the response has an id
#   an open row                   → still held: marker, no new row (this is the
#                                   replay case — the player resends the whole
#                                   answers hash on every advance)
#   released                      → the text stays in the answer
#   removed                       → the slot becomes nil, the marker says "removed"
#
# The two calls straddle the save because a new response has no id to attach
# rows to until it is saved; PlayerController wraps both in one transaction so
# a marker can never be committed without its row (that would lose the text).
module Moderation
  module Hold
    module_function

    Item = Struct.new(:key, :slot, :text, :digest, :question, :scrub_hits, keyword_init: true)

    # The player must not be able to plant a marker: a crafted
    # `{ "value": null, "held": { "value": true } }` would count as an answer
    # with nothing behind it. Called on the incoming payload before it is
    # merged with what is stored (which may legitimately carry markers).
    def strip_markers(answers)
      return answers unless answers.is_a?(Hash)

      answers.each_with_object({}) do |(key, entry), out|
        out[key] = entry.is_a?(Hash) && entry.key?("held") ? entry.except("held") : entry
      end
    end

    # `scrub_hits` is what an earlier scrub of the same payload removed (the
    # controller scrubs at merge time, before the quiz grader reads the
    # answer); the scrub here is idempotent, so it finds nothing new, and the
    # earlier counts are what the held row should record.
    def extract!(resp, survey, scrub_hits: {})
      answers = resp.answers
      return [] unless answers.is_a?(Hash)

      cards = Array(survey.cards)
      scrubbed, hits = Scrub.answers(cards, answers)
      hits = merge_hits(scrub_hits, hits)
      unless Moderation.hold_enabled?
        resp.answers = scrubbed
        return []
      end

      existing = existing_rows(resp)
      items    = []
      out      = scrubbed.dup

      FreeTextSlots.each(cards, scrubbed) do |key, slot, text, card|
        # A correct free-text quiz answer matches one of the creator's own
        # accepted answers — a closed set the creator wrote, not prose — so it
        # is shown, and scored, straight away. A wrong one is whatever the
        # respondent typed, and is held like any other text.
        next if slot == "value" && card && QuizGrading.graded?(card) && QuizGrading.correct?(card, text)

        digest = HeldText.digest_for(text)
        row    = existing[[ key.to_i, slot, digest ]]
        next if row&.status == "released"

        entry = out[key].dup
        held  = entry["held"].is_a?(Hash) ? entry["held"].dup : {}
        if row&.status == "removed"
          held[slot] = "removed"
        else
          held[slot] = true
          if row.nil? || row.status == "superseded"
            items << Item.new(key: key, slot: slot, text: text, digest: digest,
                              question: card&.dig("text").to_s.first(300).presence,
                              scrub_hits: hits[key] || {})
          end
        end
        entry[slot]   = nil
        entry["held"] = held
        out[key]      = entry
      end

      resp.answers = out
      items
    end

    # Write the rows for what extract! held, supersede any earlier undecided
    # text in the same slot, and schedule the screen. Idempotent against a
    # concurrent duplicate write: the unique index on (response, card, slot,
    # digest) turns the second insert into a find.
    def persist!(resp, items)
      return if items.empty?

      now = Time.current
      items.each do |item|
        row = resp.held_texts.create_or_find_by!(card_index: item.key.to_i, slot: item.slot, text_digest: item.digest) do |r|
          r.survey_id       = resp.survey_id
          r.organisation_id = resp.survey.organisation_id
          r.text            = item.text
          r.question        = item.question
          r.scrub_hits      = item.scrub_hits
        end
        row.update!(status: "pending", screen_attempts: 0, last_screen_error: nil) if row.status == "superseded"

        # The respondent replaced this slot's text before it was decided. The
        # old text is no longer their answer; a person need not read it and
        # the screen need not spend a call on it. Rows already being screened
        # finish on their own — current_for_slot? stops them touching the
        # answer — and a safeguarding row is kept for a person regardless.
        resp.held_texts.where(card_index: item.key.to_i, slot: item.slot)
            .where.not(id: row.id).where(status: %w[pending review])
            .update_all(status: "superseded", purge_after: now + Moderation::REMOVED_RETENTION, updated_at: now)
      end

      schedule_screen(resp)
    end

    # One screen per response per short window: a respondent's texts arrive
    # one card at a time, and batching them into a single Claude call is both
    # cheaper and gives the screen the rest of their answers as context. The
    # same claim-a-window debounce Response uses for its broadcasts; the sweep
    # (SweepHeldTextsJob) re-enqueues anything a lost job leaves pending.
    SCREEN_DEBOUNCE = 10.seconds

    def schedule_screen(resp)
      claimed = Rails.cache.write("moderation:screen:#{resp.id}", 1,
                                  unless_exist: true, expires_in: SCREEN_DEBOUNCE)
      return unless claimed

      ScreenHeldTextsJob.set(wait: SCREEN_DEBOUNCE).perform_later(resp.id)
    end

    def existing_rows(resp)
      return {} unless resp.persisted?

      resp.held_texts.index_by { |r| [ r.card_index, r.slot, r.text_digest ] }
    end

    # { key => { pattern => count } } summed across two scrubs.
    def merge_hits(a, b)
      a = a.is_a?(Hash) ? a : {}
      b = b.is_a?(Hash) ? b : {}
      a.merge(b) { |_key, x, y| x.merge(y) { |_pattern, m, n| m + n } }
    end
  end
end
