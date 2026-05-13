module OrganisationScope
  extend ActiveSupport::Concern

  included do
    before_action :set_current_organisation
    helper_method :current_organisation, :current_membership
  end

  private

  def set_current_organisation
    org_id = session[:current_organisation_id]
    membership = Current.user.memberships.includes(:organisation).find_by(organisation_id: org_id) ||
                 Current.user.memberships.includes(:organisation).first
    unless membership
      redirect_to new_session_path, alert: "No organisation found." and return
    end
    Current.organisation = membership.organisation
    session[:current_organisation_id] = Current.organisation.id
  end

  def current_organisation
    Current.organisation
  end

  def current_membership
    Current.user.memberships.find_by(organisation: Current.organisation)
  end

  def require_admin!
    redirect_to root_path, alert: "Not authorised." unless current_membership&.admin?
  end

  def require_creator_org!
    return if current_organisation&.creator?
    redirect_to alliance_vertos_path
  end
end
