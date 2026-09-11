# The creator's side of the Language check screen: every card's wording in
# every language the Verto has, primary line first, with the same approve /
# edit / comment actions the reviewer link offers.
#
# One screen rather than a panel in the editor, because the job it serves is
# not the job the editor serves. The editor is one card at a time in one
# language; this is one question across three languages, read down the page.
# The editor's locale switcher stays exactly as it was — a creator writing
# Spanish still writes it there — and this is where somebody CHECKS it.
#
# Open to every role, like the Share panel and for the same reason: reading
# the wording and saying whether it is right is what a viewer seat is for.
# Minting a review link is admin-only (LanguageCheckLinksController) — handing
# an account-less stranger the ability to rewrite live copy is an account-level
# decision, the same bar as a partner share.
class LanguageChecksController < ApplicationController
  include RecordsLanguageChecks

  before_action :set_survey

  # GET /surveys/:id/language_check
  def show
    @cards  = LanguageCheckLines.for(@survey)
    @checks = LanguageCheck.index_for(@survey)
    @notes  = LanguageCheckNote.index_for(@survey)
    @links  = @survey.language_check_links.order(created_at: :desc)
    @locales = @survey.verto_locales
    # Mirrors review_may_edit? below, so the page offers exactly the buttons
    # the endpoint would honour — a viewer seat is shown no Edit control rather
    # than one that bounces.
    @editable = can_edit_vertos?
    @shared = false
  end

  # POST /surveys/:id/language_check/lines
  # One endpoint for all three verbs, because the screen posts one line at a
  # time and the only thing that varies is which field of the row is written.
  def update_line
    outcome =
      case params[:verb].to_s
      when "approve"          then record_language_decision(@survey, **line_params, status: "approved")
      when "request_changes"  then record_language_decision(@survey, **line_params, status: "changes_requested")
      when "reset"            then record_language_decision(@survey, **line_params, status: "pending")
      when "edit"             then record_language_edit(@survey, **line_params, fields: edit_fields)
      when "note"             then record_language_note(@survey, **line_params, body: params[:body])
      else :unknown_line
      end

    redirect_to survey_language_check_path(@survey, anchor: "line-#{params[:cid]}-#{params[:locale]}",
                                                    filter: params[:filter].presence),
                alert: (t("language_check.action_failed") if outcome == :unknown_line)
  end

  private

  def set_survey
    @survey = Current.organisation.surveys.kept.without_report_text.find(params[:id])
  end

  def line_params
    { cid: params[:cid].to_s, locale: params[:locale].to_s }
  end

  # Only the fields the screen actually renders an input for, and always as a
  # plain hash of scalars/arrays — `permit!` on a nested params hash from a
  # form is how an unexpected key reaches a model write.
  def edit_fields
    raw = params[:fields]
    return {} unless raw.respond_to?(:permit)
    raw.permit(:text, :description, :explanation,
               options: [], responses: [], pages: [ :id, :text ]).to_h
  end

  # Who is acting, for the record on the row. A signed-in creator is a real
  # identity; the name is carried alongside so the screen reads the same
  # whether the line was ruled on here or through a link.
  def review_actor
    { user: Current.user, name: Current.user&.name, link: nil }
  end

  # The creator sees every language their Verto has.
  def review_scope(survey)
    survey.verto_locales
  end

  # A viewer seat reads the wording and rules on it; it does not rewrite the
  # Verto. That is the same line OrganisationScope draws everywhere else
  # (require_verto_editing!), and it has to be drawn here too — this screen is
  # a write path into `cards` like any other, just a narrower one.
  #
  # The live-edit LOCK is a separate question, and deliberately not asked here:
  # what the lock protects is the answer key (canonical option labels), and
  # Survey#apply_language_edit! refuses those itself on a locked deck while
  # still letting a typo in a live question be fixed. See its comment.
  def review_may_edit?
    can_edit_vertos?
  end
end
