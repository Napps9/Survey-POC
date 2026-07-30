# One in-flight "generate a flow" request.
#
# #generate_flow ran FlowGenerator plus a translation pass inline on a Puma
# request thread: one Claude call for the flow, then one per secondary locale.
# On a 5-language Verto that's six sequential 120s-timeout calls, and with three
# threads on one worker a couple of concurrent generations took the whole app
# down. Same fix as VertoBuild and ReportRender — the request records a row,
# enqueues a job and returns; the editor polls this and splices when it's ready.
class CreateFlowGenerations < ActiveRecord::Migration[8.1]
  def change
    create_table :flow_generations do |t|
      t.references :survey, null: false, foreign_key: true
      t.references :user,   null: false, foreign_key: true
      t.string :status, null: false, default: "pending"
      # The request's brief: prompt, the answer being wired from, its card text.
      t.json :payload, null: false, default: {}
      # The generated cards, cids stamped and translations merged. Card JSON
      # rather than rendered HTML: the slow part is Claude, and rendering belongs
      # in a request that has a view context, not in the job.
      t.json :cards, null: false, default: []
      t.string :flow_name
      t.text :error_message
      t.timestamps
    end

    add_index :flow_generations, [ :survey_id, :created_at ]
    add_index :flow_generations, :status
  end
end
