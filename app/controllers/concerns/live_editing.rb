# The editing lock as THIS REQUEST sees it.
#
# Survey#editing_locked? is a fact about the Verto — live, or answered — and
# stays that way. Whether the person asking may edit it regardless is a fact
# about the account (LiveEditAccess), so the two are combined here, at the
# controller boundary, and nowhere else: every write action in SurveysController
# and every editor partial asks `editing_locked?(survey)` instead of the model
# directly, so one predicate decides both what the server refuses and what the
# editor offers. A locked Verto never shows an affordance that would come back
# 423, and an allowed account never meets a 423 the editor didn't warn about.
#
# Included in ApplicationController rather than SurveysController because the
# card row partial is also rendered by FlowGenerationsController (via
# RendersCardHtml) and reads the same predicate.
module LiveEditing
  extend ActiveSupport::Concern

  included do
    helper_method :editing_locked?, :live_edit_override?
  end

  private

  # The signed-in account may edit Vertos the lock would otherwise freeze.
  def live_edit_override?
    LiveEditAccess.allowed?(Current.user)
  end

  # Locked for the current request: the Verto's own lock, unless this account
  # is allowed past it. `live_edit_override?` alone says nothing about whether
  # the override is actually IN USE on this Verto — a draft needs no override —
  # so views that want to warn about live editing check both:
  # `!editing_locked?(survey) && survey.editing_locked?`.
  def editing_locked?(survey)
    survey.editing_locked? && !live_edit_override?
  end
end
