class AddResultsShareToSurveys < ActiveRecord::Migration[8.1]
  def change
    add_column :surveys, :results_share_token, :string
    add_index  :surveys, :results_share_token, unique: true

    # Pausing keeps the token (and the URL) valid but takes the page down —
    # mirrors SurveyLink#active, so "resume" doesn't require handing out a new
    # link. Defaults true: minting a token is itself the enable step.
    add_column :surveys, :results_share_active, :boolean, default: true, null: false

    # A shared-results PDF render has no signed-in requester — see
    # ReportRender#shared_request? / RenderReportPdfJob's cached-only branch.
    change_column_null :report_renders, :user_id, true
  end
end
