class SurveysController < ApplicationController
  def new
  end

  def generate
    theme        = params[:theme].to_s.strip
    audience_age = params[:audience_age].to_s.strip
    key_insight  = params[:key_insight].to_s.strip
    notes        = params[:notes].to_s.strip

    if theme.empty? || audience_age.empty? || key_insight.empty?
      flash.now[:alert] = "Theme, audience age, and key insight are all required."
      return render :new, status: :unprocessable_entity
    end

    @survey = SurveyGenerator.new.call(
      theme: theme,
      audience_age: audience_age,
      key_insight: key_insight,
      notes: notes
    )
    render partial: "survey", locals: { survey: @survey }
  rescue => e
    Rails.logger.error("[SurveyGenerator] #{e.class}: #{e.message}")
    flash.now[:alert] = "Generation failed: #{e.message}"
    render :new, status: :unprocessable_entity
  end
end
