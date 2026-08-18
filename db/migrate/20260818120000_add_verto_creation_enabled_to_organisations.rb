# A staff-granted capability flag, the same shape as funder_enabled: some client
# accounts have their Vertos built FOR them by the Playverto team and should not
# see a Create affordance at all.
#
# Defaults to true so every existing organisation is untouched — this only ever
# turns OFF, for the accounts we explicitly restrict.
class AddVertoCreationEnabledToOrganisations < ActiveRecord::Migration[8.1]
  def change
    add_column :organisations, :verto_creation_enabled, :boolean, default: true, null: false
  end
end
