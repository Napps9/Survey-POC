class Current < ActiveSupport::CurrentAttributes
  attribute :session, :organisation
  delegate :user, to: :session, allow_nil: true
end
