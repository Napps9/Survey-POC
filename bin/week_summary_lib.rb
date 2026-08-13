# frozen_string_literal: true

# Pure build/parse logic for bin/trello_week_summary — aggregation, card
# naming, description rendering, and the Claude highlights prompt. No I/O in
# this file (the CLI owns every network call), so test/lib can cover it
# without stubbing anything.

require "date"
require_relative "trello_client"

module WeekSummary
  # Shared identity of the summary card: the CLI looks an existing card up by
  # this prefix, and aggregate excludes matching cards from their own totals.
  # CLAUDE.md reserves the prefix — regular trello_log titles must not use it.
  SUMMARY_CARD_PREFIX = "Week summary"
  # Trello's hard cap on card descriptions is 16,384 chars — truncate a little
  # under it so the marker itself always fits.
  MAX_DESC_CHARS = 16_000
  FALLBACK_BULLET_CAP = 15
  DESC_SNIPPET_CHARS = 200

  def self.summary_card?(card)
    card["name"].to_s.start_with?(SUMMARY_CARD_PREFIX)
  end

  # The card's story points from its numeric label ("1".."13"), nil if
  # unpointed. .max guards against a card anomalously carrying several.
  def self.points_for(card)
    Array(card["labels"]).filter_map { |l| Integer(l["name"], exception: false) if TrelloClient::FIB_LABEL_COLORS.key?(l["name"]) }.max
  end

  def self.aggregate(cards)
    work = cards.reject { |c| summary_card?(c) }
    points = work.filter_map { |c| points_for(c) }
    {
      "cards" => work.size,
      "points" => points.sum,
      "pointed" => points.size,
      "unpointed" => work.size - points.size,
      "frontend" => work.count { |c| c["desc"].to_s.include?("## Frontend") },
      "backend" => work.count { |c| c["desc"].to_s.include?("## Backend") },
      "checks_done" => work.sum { |c| c.dig("badges", "checkItemsChecked").to_i },
      "checks_total" => work.sum { |c| c.dig("badges", "checkItems").to_i }
    }
  end

  def self.card_name(totals)
    "#{SUMMARY_CARD_PREFIX} — #{totals['points']} pts · #{totals['cards']} #{totals['cards'] == 1 ? 'card' : 'cards'}"
  end

  # Deterministic stand-in for the Claude highlights: the week's cards by
  # points descending (ties keep list order = newest first), capped.
  def self.fallback_highlights(cards)
    work = cards.reject { |c| summary_card?(c) }
    ranked = work.sort_by.with_index { |c, i| [ -(points_for(c) || -1), i ] }
    bullets = ranked.first(FALLBACK_BULLET_CAP).map do |c|
      pts = points_for(c)
      "- #{c['name']} (#{pts ? "#{pts} pts" : 'unpointed'})"
    end
    rest = work.size - bullets.size
    bullets << "- …and #{rest} more #{rest == 1 ? 'card' : 'cards'}" if rest.positive?
    bullets.join("\n")
  end

  def self.build_claude_system
    <<~PROMPT
      You summarize one week of shipped engineering work from a Trello work log
      for a Rails survey app. You receive one line per card: story points in
      brackets ("?" = unpointed), the card title, and a truncated summary.
      Identify the 3 to 6 dominant themes of the week.

      Rules:
      - Output ONLY markdown bullets, each starting with "- ". No preamble, no
        heading, no closing sentence.
      - One bullet per theme, one sentence each: name the theme, then the
        concrete work behind it, citing the subjects of 1-3 representative
        cards. Do not enumerate cards one by one.
      - Weight themes by story points and card count; minor one-off items may
        share a single final bullet.
      - Only describe work present in the input. Do not state point totals or
        card counts — those are reported separately.
    PROMPT
  end

  def self.build_claude_user(cards, monday, totals)
    lines = cards.reject { |c| summary_card?(c) }.map do |c|
      pts = points_for(c)
      snippet = c["desc"].to_s.gsub(/\s+/, " ").strip[0, DESC_SNIPPET_CHARS]
      "- [#{pts || '?'} pts] #{c['name']}#{snippet.empty? ? '' : " — #{snippet}"}"
    end
    <<~MSG
      Week of #{TrelloClient.ordinal(monday.day)} #{monday.strftime('%B %Y')} — #{totals['cards']} cards, #{totals['points']} story points. Cards, newest first (summaries truncated to #{DESC_SNIPPET_CHARS} chars):

      #{lines.join("\n")}
    MSG
  end

  # The markdown bullets from Claude's reply, normalized — or nil when the
  # reply contains none, which the caller treats as a failed call.
  def self.extract_bullets(text)
    bullets = text.to_s.lines.filter_map do |line|
      stripped = line.strip
      "- #{Regexp.last_match(1)}" if stripped =~ /\A[-*]\s+(.*)/
    end
    bullets.empty? ? nil : bullets.first(8).join("\n")
  end

  def self.render_desc(totals:, highlights_md:, monday:, generated_on:, source:)
    sunday = monday + 6
    checks = if totals["checks_total"].positive?
      "\n- Test checklists: #{totals['checks_done']}/#{totals['checks_total']} items passing"
    else
      ""
    end
    desc = <<~DESC
      # Week of #{TrelloClient.ordinal(monday.day)} #{monday.strftime('%B %Y')} (Mon #{monday.strftime('%-d %b')} – Sun #{sunday.strftime('%-d %b')})

      ## Totals
      - **#{totals['points']} story points** across #{totals['cards']} #{totals['cards'] == 1 ? 'card' : 'cards'} (#{totals['pointed']} pointed, #{totals['unpointed']} unpointed)
      - Frontend: #{totals['frontend']} · Backend: #{totals['backend']}#{checks}

      ## Highlights
      #{highlights_md}

      _Generated #{generated_on.strftime('%Y-%m-%d')} by bin/trello_week_summary · highlights: #{source}_
    DESC
    desc.length > MAX_DESC_CHARS ? "#{desc[0, MAX_DESC_CHARS]}\n… [truncated]" : desc
  end
end
