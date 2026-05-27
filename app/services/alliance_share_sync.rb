class AllianceShareSync
  def self.ensure_shares_for(alliance:)
    ActiveRecord::Base.transaction do
      partner_org_ids = alliance.alliance_memberships.active.pluck(:organisation_id)
      alliance.alliance_vertos.includes(:survey).each do |av|
        partner_org_ids.each do |org_id|
          SurveyShare.find_or_create_by!(
            alliance_verto_id: av.id,
            partner_organisation_id: org_id
          ) { |s| s.survey_id = av.survey_id }
        end
      end
    end
  end
end
