class CreateResponses < ActiveRecord::Migration[8.1]
  def change
    create_table :responses do |t|
      t.references :survey,        null: false, foreign_key: true
      t.string     :session_token, null: false
      t.json       :answers,       null: false, default: {}
      t.string     :status,        null: false, default: "completed"
      t.timestamps
    end
    add_index :responses, :session_token, unique: true
  end
end
