# Ready-made Verto templates. The gallery (index) lets a creator start from a
# proven deck instead of a blank editor or an AI prompt; picking one (create)
# instantiates it into a real, editable Verto under the current organisation —
# no AI call, no external cost — and drops the creator straight into the editor.
class TemplatesController < ApplicationController
  # The gallery is gated as well as #create: its only action is "Use this
  # template", so leaving it reachable for a managed account would be a page of
  # buttons that all bounce.
  gate_verto_creation only: %i[ index create ]

  def index
    @templates = SurveyTemplates.all
    render :index, layout: "fullscreen"
  end

  # POST /templates/:id — instantiate the chosen template as a draft Verto,
  # in the creator's language: the content resolves in their UI locale and the
  # new Verto's default_locale IS that locale, so it starts native rather than
  # as an English deck waiting to be translated.
  def create
    locale   = I18n.locale.to_s
    cards    = SurveyTemplates.cards_for(params[:id], locale: locale)
    template = SurveyTemplates.find(params[:id])

    unless cards && template
      return redirect_to survey_templates_path, alert: t("templates.not_found")
    end

    survey = Current.organisation.surveys.create!(
      title:          SurveyTemplates.localized_name(template, locale),
      theme:          template[:theme],
      audience_age:   template[:audience_age],
      key_insight:    template[:key_insight],
      cards:          DemographicQuestions.append_to(cards, locale: locale),
      default_locale: locale,
      locales:        [ locale ],
      brand_palette:  Current.organisation.default_brand_palette.presence
    )

    redirect_to survey_path(survey),
                notice: t("templates.created", name: SurveyTemplates.localized_name(template, locale))
  end
end
