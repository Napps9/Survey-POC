class AddVerificationAndTermsToUsers < ActiveRecord::Migration[8.1]
  def up
    add_column :users, :email_verified_at, :datetime
    add_column :users, :terms_accepted_at, :datetime

    # Grandfather existing accounts as verified. They have been signing in and
    # working in the product, which is stronger evidence of address ownership
    # than a click-through would be, and retroactively locking them out of
    # publishing would break live customers to close a signup hole.
    #
    # terms_accepted_at is deliberately NOT backfilled: we do not have those
    # acceptances, and writing a timestamp we never collected would be a
    # fiction in exactly the record that is supposed to prove consent.
    execute "UPDATE users SET email_verified_at = created_at"
  end

  def down
    remove_column :users, :email_verified_at
    remove_column :users, :terms_accepted_at
  end
end
