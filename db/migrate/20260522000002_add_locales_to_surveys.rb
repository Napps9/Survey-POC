class AddLocalesToSurveys < ActiveRecord::Migration[8.1]
  def change
    add_column :surveys, :default_locale, :string, default: "en", null: false
    add_column :surveys, :locales, :json
  end
end
