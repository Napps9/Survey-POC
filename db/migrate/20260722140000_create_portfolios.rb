class CreatePortfolios < ActiveRecord::Migration[8.1]
  def change
    create_table :portfolios do |t|
      t.references :funder, null: false, foreign_key: true
      t.string   :name, null: false
      t.datetime :deleted_at
      t.timestamps
    end
    add_index :portfolios, [ :funder_id, :name ], unique: true
    add_index :portfolios, :deleted_at

    create_table :portfolio_memberships do |t|
      t.references :portfolio, null: false, foreign_key: true
      t.references :funder_membership, null: false, foreign_key: true
      t.timestamps
    end
    add_index :portfolio_memberships, [ :portfolio_id, :funder_membership_id ],
              unique: true, name: "idx_portfolio_memberships_unique"

    create_table :portfolio_common_question_sets do |t|
      t.references :portfolio, null: false, foreign_key: true
      t.references :common_question_set, null: false, foreign_key: true
      t.timestamps
    end
    add_index :portfolio_common_question_sets, [ :portfolio_id, :common_question_set_id ],
              unique: true, name: "idx_portfolio_cq_sets_unique"
  end
end
