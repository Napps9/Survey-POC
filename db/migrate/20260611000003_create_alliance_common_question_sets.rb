class CreateAllianceCommonQuestionSets < ActiveRecord::Migration[8.1]
  def change
    # Join: a Common Question set shared into an alliance, so partners can
    # see the questions the owner asks everywhere (mirrors alliance_vertos).
    create_table :alliance_common_question_sets do |t|
      t.integer :alliance_id, null: false
      t.integer :common_question_set_id, null: false
      t.timestamps
    end
    add_index :alliance_common_question_sets, :alliance_id
    add_index :alliance_common_question_sets, [ :alliance_id, :common_question_set_id ],
              unique: true, name: "idx_alliance_cq_sets_unique"
  end
end
