class Current < ActiveSupport::CurrentAttributes
  attribute :session, :organisation, :locale
  delegate :user, to: :session, allow_nil: true
end
