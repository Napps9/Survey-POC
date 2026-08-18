module OrganisationScope
  extend ActiveSupport::Concern

  included do
    before_action :set_current_organisation
    helper_method :current_organisation, :current_membership, :can_create_vertos?

    # Records which actions the creation gate covers, so a test can assert no
    # creation endpoint slipped past it. Same idiom (and same reason) as
    # ThrottlesAiSpend's ai_throttled_actions.
    class_attribute :verto_creation_actions, default: [], instance_writer: false
  end

  class_methods do
    # Installs the gate AND records what it covers. Accumulates rather than
    # overwrites so a controller may declare it more than once.
    def gate_verto_creation(only:)
      actions = Array(only).map(&:to_sym)
      self.verto_creation_actions = (verto_creation_actions + actions).uniq
      before_action :require_verto_creation!, only: actions
    end
  end

  private

  def set_current_organisation
    org_id = session[:current_organisation_id]
    membership = Current.user.memberships.includes(:organisation).find_by(organisation_id: org_id) ||
                 Current.user.memberships.includes(:organisation).first
    unless membership
      redirect_to new_session_path, alert: t("flash.organisation_scope.no_organisation") and return
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

  # Whether a Verto can be created in the account currently being acted in.
  #
  # Two ways to qualify: the account creates its own Vertos, or the actor is
  # Playverto staff. The second is what makes a MANAGED account work — the
  # client cannot create, but the Playverto person building their Verto is
  # inside the same account and must be able to.
  #
  # Also the view predicate: every Create affordance is hidden on the same
  # answer that refuses the request, so a restricted user never meets a button
  # that bounces them.
  def can_create_vertos?
    return false unless Current.organisation

    Current.organisation.verto_creation_enabled? || PlayvertoStaff.member?(Current.user)
  end

  # Deliberately enforced HERE, at the controller boundary, and not as a
  # validation on Survey. Vertos are also created by the deck importer
  # (VertoCsvImporter), the demo seeder and BuildVertoJob — all of which build
  # Vertos FOR an account, restricted or not, and a model-level rule would
  # break them. Every user-reachable door is gated below; the job is only ever
  # enqueued from one of them.
  def require_verto_creation!
    return if can_create_vertos?

    deny_verto_creation
  end

  # A redirect answers an HTML request fine, but a fetch() asking for JSON gets
  # a 302 to a page of HTML it can't parse — which reads to the caller as a
  # mystery failure rather than "you're not an admin". Answer each in its own
  # language.
  def require_admin!
    return if current_membership&.admin?

    if request.format.json?
      render json: { ok: false, error: t("flash.organisation_scope.not_authorised") }, status: :forbidden
    else
      redirect_to root_path, alert: t("flash.organisation_scope.not_authorised")
    end
  end

  # Same two-language shape as require_admin!, for the same reason —
  # verto_builds#show is polled as JSON by the wait screen.
  def deny_verto_creation
    if request.format.json?
      render json: { ok: false, error: t("flash.organisation_scope.verto_creation_disabled") },
             status: :forbidden
    else
      redirect_to root_path, alert: t("flash.organisation_scope.verto_creation_disabled")
    end
  end
end
