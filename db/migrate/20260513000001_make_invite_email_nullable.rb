class MakeInviteEmailNullable < ActiveRecord::Migration[8.1]
  def change
    change_column_null :invites, :email_address, true
  end
end
