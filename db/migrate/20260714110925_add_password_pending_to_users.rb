class AddPasswordPendingToUsers < ActiveRecord::Migration[8.1]
  def change
    # True from the moment PartnershipAccountsController creates an
    # owner-provisioned partner account until the partner sets their own
    # password via PartnerAccountSetupsController — UI-only (a "setup
    # pending" badge for the owner), not a login gate: nobody knows the
    # random password set at creation until it's replaced.
    add_column :users, :password_pending, :boolean, default: false, null: false
  end
end
