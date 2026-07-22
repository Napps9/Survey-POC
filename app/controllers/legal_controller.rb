class LegalController < ApplicationController
  allow_unauthenticated_access
  skip_before_action :set_current_organisation

  def privacy
  end

  def terms
  end

  def cookie_policy
  end
end
