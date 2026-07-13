class PartnershipShareSync
  def self.ensure_shares_for(partnership:)
    ActiveRecord::Base.transaction do
      partner_org_ids = partnership.partnership_memberships.active.pluck(:organisation_id)
      partnership.partnership_vertos.includes(:survey).each do |av|
        partner_org_ids.each do |org_id|
          SurveyShare.find_or_create_by!(
            partnership_verto_id: av.id,
            partner_organisation_id: org_id
          ) { |s| s.survey_id = av.survey_id }
        end
      end
    end
  end
end
