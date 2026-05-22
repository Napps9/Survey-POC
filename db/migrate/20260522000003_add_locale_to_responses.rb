class AddLocaleToResponses < ActiveRecord::Migration[8.1]
  def change
    add_column :responses, :locale, :string
  end
end
