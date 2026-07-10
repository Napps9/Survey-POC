# Ready-made Verto templates. The gallery (index) lets a creator start from a
# proven deck instead of a blank editor or an AI prompt; picking one (create)
# instantiates it into a real, editable Verto under the current organisation —
# no AI call, no external cost — and drops the creator straight into the editor.
class TemplatesController < ApplicationController
  def index
    @templates = SurveyTemplates.all
    render :index, layout: "fullscreen"
  end

  # POST /templates/:id — instantiate the chosen template as a draft Verto.
  def create
    cards = SurveyTemplates.cards_for(params[:id])
    template = SurveyTemplates.find(params[:id])

    unless cards && template
      return redirect_to survey_templates_path, alert: t("templates.not_found")
    end

    survey = Current.organisation.surveys.create!(
      title:          template[:name],
      theme:          template[:theme],
      audience_age:   template[:audience_age],
      key_insight:    template[:key_insight],
      cards:          DemographicQuestions.append_to(cards),
      default_locale: "en",
      locales:        [ "en" ],
      brand_palette:  Current.organisation.default_brand_palette.presence
    )

    redirect_to survey_path(survey), notice: t("templates.created", name: template[:name])
  end
end
