# Shared plumbing for every Comms controller: the fullscreen shell and the
# Playverto-membership gate. The routing constraint already 404s non-members
# before the stack runs; this before_action repeats the check as defence in
# depth and raises RecordNotFound so anything that bypasses the router still
# renders the same 404 the router gives.
class Comms::BaseController < ApplicationController
  layout "fullscreen"

  before_action :require_comms_access

  private

  def require_comms_access
    raise ActiveRecord::RecordNotFound unless CommsAccess.allowed?(Current.user)
  end
end
