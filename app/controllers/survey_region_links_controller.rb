class SurveyRegionLinksController < ApplicationController
  # Region tags: each link tags a Verto with a region (country + optional
  # sub-region label) and mints a /play URL that attributes responses to it.
  def create
    survey = Current.organisation.surveys.kept.find(params[:id])
    link   = survey.survey_region_links.create(
      country_code: params[:country_code],
      label:        params[:label].to_s.strip.presence
    )
    if link.persisted?
      redirect_to survey_path(survey)
    else
      redirect_to survey_path(survey), alert: "Couldn't add region — #{link.errors.full_messages.first}"
    end
  end

  def destroy
    survey = Current.organisation.surveys.kept.find(params[:id])
    survey.survey_region_links.find(params[:link_id]).destroy!
    redirect_to survey_path(survey)
  end
end
