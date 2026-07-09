module ResolvesResultSegments
  extend ActiveSupport::Concern

  private

  # Response segments for the results filter: always "Overall", plus a
  # "Direct link" and one entry per partner share when this Verto is shared,
  # plus one entry per region tag when this Verto is region-tagged.
  # Each entry is { id:, label:, scope:, count: }. Shared by the results screen
  # and the CSV / Google Sheets exports so they all scope responses identically.
  def result_segments(survey, base)
    segments = [ { id: "overall", label: "Overall", scope: base, count: base.count } ]

    shares = survey.survey_shares
                   .includes(:partner_organisation, alliance_verto: :alliance)
                   .order(:created_at)

    if shares.any?
      direct = base.where(survey_share_id: nil)
      if (direct_count = direct.count).positive?
        segments << { id: "direct", label: "Direct link", scope: direct, count: direct_count }
      end

      shares.each do |share|
        scope = base.where(survey_share_id: share.id)
        alliance_name = share.alliance_verto&.alliance&.name
        label = alliance_name ? "#{share.display_name} · #{alliance_name}" : share.display_name
        segments << { id: "share_#{share.id}", label: label, scope: scope, count: scope.count }
      end
    end

    # Region segments come from the responses themselves, so they cover both
    # link-minted regions and ask-players self-declared ones. Ordered by
    # volume and capped, so a Verto with hundreds of regions doesn't explode
    # the filter row. Ids hash the region key — stable across requests.
    # reorder(nil) drops base's `ORDER BY created_at`: Postgres rejects an
    # ORDER BY column that isn't in the GROUP BY (SQLite quietly allows it).
    # Small-cell suppression: a region with fewer than MIN_REGION_SAMPLE_SIZE
    # respondents never gets its own segment — see Response for why.
    region_counts = base.reorder(nil).where.not(region_country: nil)
                        .group(:region_country, :region_label).count
                        .select { |_, count| count >= Response::MIN_REGION_SAMPLE_SIZE }
    region_counts.sort_by { |_, count| -count }.first(REGION_SEGMENT_CAP).each do |(country, label), count|
      name    = WorldRegions.name_for(country)
      display = label.present? ? "#{name} · #{label}" : name
      segments << {
        id:           "region_#{Digest::MD5.hexdigest("#{country}|#{label}").first(10)}",
        label:        "🌍 #{display}",
        country:      country,
        region_label: label,
        scope:        base.where(region_country: country, region_label: label),
        count:        count
      }
    end

    segments
  end

  REGION_SEGMENT_CAP = 30

  # The base response scope, plus the segments and the active segment selected
  # by params[:segment]. Returns [base, segments, active_segment].
  #
  # Base is every *responder* — anyone who answered at least one question, not
  # only those who reached Submit — so the per-question results reflect all the
  # data collected, including partial responses that stopped part-way. The
  # aggregator counts each card off its own answers, so an unfinished response
  # simply contributes to the questions it did reach. (Completion is still
  # surfaced separately as the dashboard's completion rate.)
  def resolve_result_segments(survey, segment_param)
    base     = survey.responses.where(answered: true).order(created_at: :desc)
    segments = result_segments(survey, base)
    active   = segments.find { |s| s[:id] == segment_param } || segments.first
    [ base, segments, active ]
  end
end
