# The wait screen for a Verto being built in the background, and the endpoint it
# polls. Scoped to the current organisation like every other survey path, so a
# build id from another account is simply not found.
class VertoBuildsController < ApplicationController
  layout "fullscreen"

  # Defence in depth: a managed account can never start a build, so it has no
  # business on the wait screen either. Gated for the JSON poll as much as the
  # HTML — deny_verto_creation answers both.
  gate_verto_creation only: %i[ show ]

  # GET /verto_builds/:id       — the "building your Verto" screen
  # GET /verto_builds/:id.json  — what that screen polls
  def show
    build = Current.organisation.verto_builds.find(params[:id])

    # A build whose worker died mid-run (this instance restarts its worker at
    # 85% RSS) would otherwise poll as "running" forever, which reads as a hung
    # app. Surface it as a failure the creator can retry instead.
    build.fail!("This took longer than expected and stopped. Please try again.") if build.stale?

    respond_to do |format|
      format.html do
        # Nothing left to wait for — don't show a spinner over a finished build.
        return redirect_to(finished_path(build)) if build.succeeded? && finished_path(build)
        return redirect_to new_survey_path, alert: build_failure_message(build) if build.failed?

        # No top nav on the wait screen. The wizard's overlay already hides it
        # (body.generating-overlay-active) and the editor this forwards to hides
        # it too, so leaving it here made the bar blink back for the duration of
        # the build — the one seam in an otherwise continuous handoff. Dropping
        # it also lifts the layout's 56px offset, so the stage is truly
        # full-bleed rather than 56px short of it.
        @hide_main_nav = true
        @build = build
        render :show
      end

      format.json { render json: build_status(build) }
    end
  end

  private

  def build_status(build)
    status = { status: build.status }
    status[:redirect_to] = finished_path(build) if build.succeeded?
    status[:error]       = build_failure_message(build) if build.failed?
    status.compact
  end

  # Where a finished build sends the creator. A generation ends at its Verto; an
  # import stops one step short, because whether its questions go straight to
  # the editor or pause at the review screen is the creator's decision to make.
  def finished_path(build)
    return resume_import_path(build) if build.import? && build.result
    return survey_path(build.survey) if build.survey

    nil
  end

  def build_failure_message(build)
    "We couldn't generate your Verto — #{build.error_message}"
  end
end
