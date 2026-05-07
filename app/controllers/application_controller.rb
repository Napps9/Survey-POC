class ApplicationController < ActionController::Base
  include Authentication
  include OrganisationScope
  allow_browser versions: :modern
end
