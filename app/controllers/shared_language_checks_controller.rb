# The public half of the Language check screen: /language-check/:token, the
# page a creator sends to somebody who speaks the language but has no reason to
# own a Playverto account.
#
# Access posture — the token IS the authorisation, exactly as for /results/:token
# and a play link. So: noindex (ApplicationController::NOINDEX_PATHS), Disallow
# in robots.txt, rate limits on every action, and a pause (active: false) that
# keeps the URL while turning it off, distinct from a revoke that destroys it.
#
# What a link holder can reach is narrower than what the creator can, in three
# ways that are enforced here rather than in the view:
#
#   * only the languages the link was minted for (LanguageCheckLink#visible_locales)
#   * only the wording — never the results, the respondents, the settings, or
#     any other Verto in the account
#   * only the words, not the deck: nothing on this page adds, deletes,
#     reorders or re-types a card. A reviewer changes what a question SAYS,
#     never what it IS.
#
# A read-only link (can_edit: false) narrows it again to approving and
# commenting. That is a real posture, not a UI state — Survey#apply_language_edit!
# is never reached, and the check is in RecordsLanguageChecks, not the template.
class SharedLanguageChecksController < ApplicationController
  include RecordsLanguageChecks

  layout "fullscreen"
  skip_before_action :require_authentication
  skip_before_action :set_current_organisation
  # Nobody holding this link has a session to carry a CSRF token. Same
  # reasoning, and the same null_session treatment, as PlayerController#submit
  # and SharedResultsController#create_render.
  protect_from_forgery with: :null_session, only: %i[ update_line identify ]

  before_action :set_link

  # Distinct `name:`s so reading the page and acting on it do not share one
  # per-IP counter — Rails keys on [scope, name, ip] and `name` defaults to nil,
  # which is how a poller burns a page's own budget (see SharedResultsController).
  rate_limit to: 120, within: 1.minute, only: :show, name: "language_check_reads",
             with: -> { render plain: "Too many requests — please slow down.", status: :too_many_requests }
  # A review session is genuinely write-heavy — a reviewer ticks a line a
  # second down a long deck — so this is looser than the shared-results write
  # limit and still far below anything that could be used to hammer the deck.
  rate_limit to: 90, within: 1.minute, only: %i[ update_line identify ], name: "language_check_writes",
             with: -> { render plain: "Too many requests — please slow down.", status: :too_many_requests }

  # GET /language-check/:token
  def show
    @link.touch_seen!
    @locales  = @link.visible_locales
    @cards    = LanguageCheckLines.for(@survey)
    @checks   = LanguageCheck.index_for(@survey)
    @notes    = LanguageCheckNote.index_for(@survey)
    @editable = @link.editable?
    @shared   = true
    @reviewer_name = reviewer_name
  end

  # POST /language-check/:token/name — the reviewer says who they are, once,
  # so their approvals carry a name. Optional by design: somebody who would
  # rather not be named still gets to review, and the notes read "A reviewer".
  def identify
    cookies.signed[reviewer_cookie] = {
      value: sanitize_reviewer_name(params[:reviewer_name]).to_s,
      expires: 90.days.from_now, httponly: true, same_site: :lax
    }
    redirect_to shared_language_check_path(@link.token)
  end

  # POST /language-check/:token/lines
  def update_line
    outcome =
      case params[:verb].to_s
      when "approve"         then record_language_decision(@survey, **line_params, status: "approved")
      when "request_changes" then record_language_decision(@survey, **line_params, status: "changes_requested")
      when "reset"           then record_language_decision(@survey, **line_params, status: "pending")
      when "edit"            then record_language_edit(@survey, **line_params, fields: edit_fields)
      when "note"            then record_language_note(@survey, **line_params, body: params[:body])
      else :unknown_line
      end

    redirect_to shared_language_check_path(@link.token,
                                           anchor: "line-#{params[:cid]}-#{params[:locale]}",
                                           filter: params[:filter].presence),
                alert: (t("language_check.action_failed") if outcome == :unknown_line)
  end

  private

  # A paused link, a revoked one, and one whose Verto has been deleted all
  # arrive at the same page. They are different facts, and none of them is the
  # holder's business: the only thing a link that does not work should say is
  # that it does not work.
  def set_link
    @link = LanguageCheckLink.active.find_by(token: params[:token])
    @survey = @link&.survey
    return unavailable if @link.nil? || @survey.nil? || @survey.deleted?

    # A link minted for a language the Verto no longer has is not a reviewable
    # page — better to say so than to render an empty board.
    unavailable if @link.visible_locales.empty?
  end

  def unavailable
    render "unavailable", status: :not_found
  end

  def line_params
    { cid: params[:cid].to_s, locale: params[:locale].to_s }
  end

  def edit_fields
    raw = params[:fields]
    return {} unless raw.respond_to?(:permit)
    raw.permit(:text, :description, :explanation,
               options: [], responses: [], pages: [ :id, :text ]).to_h
  end

  def review_actor
    { user: nil, name: reviewer_name, link: @link }
  end

  def review_scope(_survey)
    @link.visible_locales
  end

  def review_may_edit?
    @link.editable?
  end

  # Per-link, so one person reviewing two Vertos is not renamed by the second,
  # and signed so the name in the audit trail is one this app wrote rather than
  # one the browser was told to send.
  def reviewer_cookie
    :"language_check_name_#{@link.id}"
  end

  def reviewer_name
    sanitize_reviewer_name(cookies.signed[reviewer_cookie])
  end
end
