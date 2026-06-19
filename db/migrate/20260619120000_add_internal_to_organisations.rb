# Mark an organisation as "internal" — VertoNow's own test/staff orgs — so the
# Blazer BI dashboards can exclude them and report real customer usage. Flagged
# via bin/rails 'organisations:mark_internal[slug]'. Deny-by-default: everything
# is a real org until explicitly marked.
class AddInternalToOrganisations < ActiveRecord::Migration[8.1]
  def change
    add_column :organisations, :internal, :boolean, default: false, null: false
  end
end
