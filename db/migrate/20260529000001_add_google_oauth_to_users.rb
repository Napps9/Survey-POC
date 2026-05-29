class AddGoogleOauthToUsers < ActiveRecord::Migration[8.1]
  def change
    # OAuth credentials for the per-user "Connect to Google Sheets" export.
    # Tokens are :text because Active Record Encryption payloads are longer
    # than the plaintext. The refresh token is the long-lived credential; the
    # access token + expiry are an optional cache.
    add_column :users, :google_refresh_token,     :text
    add_column :users, :google_access_token,      :text
    add_column :users, :google_token_expires_at,  :datetime
    add_column :users, :google_email,             :string
    add_column :users, :google_connected_at,      :datetime
  end
end
