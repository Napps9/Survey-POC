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

  # A redirect answers an HTML request fine, but a fetch() asking for JSON gets
  # a 302 to a page of HTML it can't parse — which reads to the caller as a
  # mystery failure rather than "you're not an admin". Answer each in its own
  # language.
  def require_admin!
    return if current_membership&.admin?

    if request.format.json?
      render json: { ok: false, error: "Not authorised." }, status: :forbidden
    else
      redirect_to root_path, alert: "Not authorised."
    end
  end
end
