module ResolvesResultSegments
  extend ActiveSupport::Concern

  private

  # Response segments for the results filter: always "Overall", plus a
  # "Direct link" and one entry per partner share when this Verto is shared.
  # Each entry is { id:, label:, scope:, count: }. Shared by the results screen
  # and the CSV / Google Sheets exports so they all scope responses identically.
  def result_segments(survey, base)
    segments = [ { id: "overall", label: "Overall", scope: base, count: base.count } ]

    shares = survey.survey_shares
                   .includes(:partner_organisation, alliance_verto: :alliance)
                   .order(:created_at)
    return segments if shares.empty?

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

    segments
  end

  # The completed-response base scope, plus the segments and the active segment
  # selected by params[:segment]. Returns [base, segments, active_segment].
  def resolve_result_segments(survey, segment_param)
    base     = survey.responses.where(status: "completed").order(created_at: :desc)
    segments = result_segments(survey, base)
    active   = segments.find { |s| s[:id] == segment_param } || segments.first
    [ base, segments, active ]
  end
end
