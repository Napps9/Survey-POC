require "set"

# One-way removal of question types the platform no longer offers.
#
# Two card kinds were withdrawn because of what they collect, not how they
# behave: `contact_form` (name, company, industry, email — the only card type
# that ever gathered identifying data) and the opt-in Neurodiversity
# demographic card (special-category data about how someone thinks). Making
# them unpickable only stops NEW ones; this takes the existing ones out of
# every deck, published or not, and drops the answers they collected.
#
# Why this can't just splice the array: answers are keyed by CARD INDEX
# (`resp.answers["3"]` is the answer to `cards[3]`), which is precisely why
# Survey#editing_locked? forbids creators from deleting a card once a Verto has
# responses. Removing a card without moving every later answer key down leaves a
# deck whose data reads cleanly and means something else entirely. So the deck
# edit and the answer re-key are one transaction, per survey.
#
# Logic and flows are safe from the re-key — they target cards by stable `cid`,
# never by index (see LogicGraph) — but they can point AT a withdrawn card, so
# dangling targets are scrubbed in the same pass. The target locations are the
# same four Survey.remap_card_logic! walks for a deck duplication.
#
# Lives here rather than inline in the migration so the re-keying is unit
# tested (test/lib/legacy_card_purge_test.rb): a wrong remap is silent, and
# produces data that looks fine.
module LegacyCardPurge
  module_function

  # Withdrawn card types, matched on `type`.
  DOOMED_TYPES = %w[ contact_form ].freeze

  # Withdrawn opt-in demographic cards, matched on `demographic_key`. Strict
  # matching is enough: unlike the location card (whose backfill had to match on
  # text because it predated the `demographic` flag), the optional demographic
  # cards were introduced with `demographic_key` already stamped by
  # SurveysController#add_demographic_card, and Survey's card sanitiser has
  # preserved it ever since. Nothing looser is worth the false positives — the
  # heuristic that would catch a stray card would also catch a creator's own
  # select-many about the same subject.
  DOOMED_DEMOGRAPHIC_KEYS = %w[ neurodiversity ].freeze

  def doomed?(card)
    return false unless card.is_a?(Hash)
    return true if DOOMED_TYPES.include?(card["type"].to_s)

    DOOMED_DEMOGRAPHIC_KEYS.include?(card["demographic_key"].to_s)
  end

  # Strip every withdrawn card from one Verto and re-key its stored answers.
  # Returns the number of cards removed; 0 (and no writes at all) when there's
  # nothing to do, so re-running over the whole table is free and idempotent.
  def purge_survey!(survey)
    cards = survey.read_attribute(:cards)
    return 0 unless cards.is_a?(Array)

    doomed = cards.each_index.select { |i| doomed?(cards[i]) }

    # The undo bin is checked independently of the deck: a creator may already
    # have deleted the card themselves, leaving it only in the bin, where
    # Survey#deleted_card would still hand it back by cid.
    old_bin = Array(survey.read_attribute(:deleted_cards))
    bin     = old_bin.reject { |entry| entry.is_a?(Hash) && doomed?(entry["card"]) }
    return 0 if doomed.empty? && bin.size == old_bin.size

    if doomed.empty?
      survey.update_column(:deleted_cards, bin)
      return 0
    end

    doomed_set  = doomed.to_set
    doomed_cids = doomed.filter_map { |i| cards[i]["cid"].to_s.presence }.to_set
    remap       = index_remap(cards.size, doomed_set)

    new_cards = cards.reject.with_index { |_card, i| doomed_set.include?(i) }
    flows     = survey.read_attribute(:flows)
    scrub_targets!(new_cards, flows, doomed_cids)

    intro = doomed_cids.include?(survey.token_intro_cid.to_s) ? nil : survey.token_intro_cid

    survey.class.transaction do
      # update_columns, not update!: the before_save sanitisers would rewrite
      # unrelated fields on old rows, which is why every card backfill in
      # db/migrate does the same.
      # results_summary is AI prose cached against a response COUNT, which this
      # doesn't change — so it would never invalidate itself and could keep
      # describing questions that no longer exist. Nulling it regenerates on the
      # next view. results_report is deliberately left alone: it is creator-edited
      # prose (results_report_edited_at), and destroying that is worse than a
      # stale sentence.
      survey.update_columns(cards: new_cards, flows: flows,
                            deleted_cards: bin, token_intro_cid: intro,
                            results_summary: nil, results_summary_response_count: nil)

      survey.responses.select(:id, :answers).find_each(batch_size: 200) do |resp|
        answers = resp.answers
        next unless answers.is_a?(Hash)

        rekeyed = rekey_answers(answers, doomed_set, remap)
        next if rekeyed == answers

        # `answered` is kept in sync by a before_save (Response#sync_answered)
        # that update_columns skips, so it has to be recomputed by hand — a
        # response whose ONLY answer was a withdrawn card has just stopped being
        # a responder, and would otherwise sit in every count as a phantom.
        Response.where(id: resp.id).update_all(
          answers: rekeyed,
          answered: rekeyed.values.any? { |a| Response.answered_entry?(a) }
        )
      end

      purge_corpus_questions!(survey, doomed_cids)
    end

    doomed.size
  end

  # The Ask Verto index stores one row per citable card, keyed by cid, and
  # `select_many` is indexable — so the Neurodiversity card has real
  # corpus_questions rows carrying its distribution. Drop them here rather than
  # waiting for a re-index: the nightly IndexCorpusEntryJob.refresh_all! repairs
  # the now-stale `position` values (written but never read), but only the sweep
  # would remove these rows, and this data should not survive until then.
  # corpus_quotes cascade via dependent: :destroy.
  def purge_corpus_questions!(survey, doomed_cids)
    return if doomed_cids.empty?

    entry = survey.corpus_entry
    return unless entry

    entry.corpus_questions.where(cid: doomed_cids.to_a).destroy_all
  end

  # old index => new index, for the cards that survive. A survivor moves down by
  # the number of withdrawn cards that sat in front of it.
  def index_remap(size, doomed_set)
    shift = 0
    (0...size).each_with_object({}) do |i, map|
      if doomed_set.include?(i)
        shift += 1
      else
        map[i] = i - shift
      end
    end
  end

  # Rebuild one response's answers against the new card positions. Anything that
  # isn't an index key is passed through untouched rather than guessed at.
  def rekey_answers(answers, doomed_set, remap)
    answers.each_with_object({}) do |(key, value), out|
      idx = Integer(key.to_s, exception: false)

      if idx.nil?
        out[key] = value
      elsif doomed_set.include?(idx)
        next # the withdrawn card's own answer — this is the data being purged
      elsif remap.key?(idx)
        out[remap[idx].to_s] = value
      else
        # An answer past the end of the deck. Not ours to interpret; leave it
        # where it is rather than silently re-point it.
        out[key] = value
      end
    end
  end

  # Clear branching that pointed at a card that no longer exists. Falling
  # through to the linear next card is the same fail-safe LogicGraph already
  # applies to an unresolvable target.
  def scrub_targets!(cards, flows, doomed_cids)
    return if doomed_cids.empty?

    Array(cards).each do |card|
      next unless card.is_a?(Hash)

      if card["logic"].is_a?(Hash)
        logic = card["logic"]
        if logic["routes"].is_a?(Array)
          logic["routes"] = logic["routes"].reject { |r| r.is_a?(Hash) && dangling?(r["to"], doomed_cids) }
        end
        logic.delete("default") if dangling?(logic["default"], doomed_cids)
        card.delete("logic") if Array(logic["routes"]).empty? && logic["default"].blank?
      end

      card.delete("next") if dangling?(card["next"], doomed_cids)
    end

    Array(flows).each do |flow|
      next unless flow.is_a?(Hash)

      flow.delete("exit") if dangling?(flow["exit"], doomed_cids)
    end
  end

  def dangling?(target, doomed_cids)
    target.is_a?(Hash) && doomed_cids.include?(target["card"].to_s)
  end
end
