class CreateCommonQuestionSets < ActiveRecord::Migration[8.1]
  def change
    create_table :common_question_sets do |t|
      t.references :organisation, null: false, foreign_key: true
      t.string  :name,            null: false
      t.string  :theme
      t.text    :key_insight
      t.string  :default_locale,  null: false, default: "en"
      t.datetime :deleted_at
      t.timestamps
    end
    add_index :common_question_sets, :deleted_at

    create_table :common_questions do |t|
      t.references :common_question_set, null: false, foreign_key: true
      t.integer :position,    null: false
      t.text    :text,        null: false
      t.text    :description
      t.string  :card_type,   null: false
      t.json    :options
      t.boolean :allow_other, null: false, default: false
      t.timestamps
    end
    add_index :common_questions, [ :common_question_set_id, :position ]
  end
end
