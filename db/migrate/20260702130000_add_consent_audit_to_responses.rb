class AddConsentAuditToResponses < ActiveRecord::Migration[8.1]
  # Persists the consent gate's agree/decline event so there's an audit trail
  # for IRB-style use — previously agreeConsent()/declineConsent() were pure
  # client-side UI with nothing written to the response row. The text snapshot
  # ties a response to the exact wording shown at that moment, so an unrelated
  # later edit to the survey's consent_text doesn't retroactively change what
  # an already-recorded response appears to have agreed to.
  def change
    add_column :responses, :consent_agreed_at, :datetime
    add_column :responses, :consent_declined_at, :datetime
    add_column :responses, :consent_text_snapshot, :text
  end
end
