# Answering "why hasn't this language translated?" from a console, because the
# screen can only ever show what was written down — and the cases that hurt are
# the ones where nothing was.
#
#   bin/rails "language_check:status[123]"     # one Verto
#   bin/rails language_check:stuck             # every language stuck anywhere
namespace :language_check do
  desc "Show every language's translation state for one Verto"
  task :status, [ :survey_id ] => :environment do |_t, args|
    survey = Survey.find(args[:survey_id])
    rows   = SurveyTranslation.index_for(survey)
    cards  = LanguageCheckLines.for(survey)
    cover  = LanguageCheckLines.coverage(cards, survey.verto_locales, survey.default_locale)

    puts "#{survey.theme.presence || survey.title} (##{survey.id}) — #{cards.size} cards"
    puts "primary: #{survey.default_locale}"
    puts

    survey.verto_locales.each do |code|
      cov = cover[code]
      row = rows[code]
      line = format("  %-6s %-14s %s", code,
                    "#{cov[:translated]}/#{cov[:total]}",
                    cov[:primary] ? "(original)" : (row ? row.display_status : "never asked for"))
      line += "  attempts=#{row.attempts}" if row && row.attempts.positive?
      line += "  started=#{row.started_at&.iso8601}" if row&.started_at
      puts line
      puts "         ↳ #{row.stalled_reason}" if row&.stalled_reason.present?
    end

    puts
    pending = Array(survey.verto_locales).reject { |c| c == survey.default_locale }
                                          .select { |c| cover[c][:translated] < cover[c][:total] }
    puts pending.empty? ? "Every language is complete." :
      "Incomplete: #{pending.join(', ')} — retry from the Language check rail, or:\n" \
      "  TranslateLocalesJob.enqueue_for(Survey.find(#{survey.id}), #{pending.inspect})"
  end

  desc "Every language stuck in progress across all Vertos"
  task stuck: :environment do
    stuck = SurveyTranslation.unfinished.select(&:stale?)
    if stuck.empty?
      puts "Nothing stuck."
      next
    end
    stuck.each do |row|
      puts format("survey=%-6s %-6s %-8s attempts=%s since=%s",
                  row.survey_id, row.locale, row.status, row.attempts,
                  (row.started_at || row.updated_at)&.iso8601)
    end
    puts "\n#{stuck.size} stuck. Re-queue all:"
    puts "  SurveyTranslation.unfinished.select(&:stale?).group_by(&:survey_id).each { |id, rs| " \
         "TranslateLocalesJob.enqueue_for(Survey.find(id), rs.map(&:locale)) }"
  end
end
