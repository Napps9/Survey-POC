class SurveysController < ApplicationController
  def new
  end

  def generate
    prompt = params[:prompt].to_s.strip

    if prompt.empty?
      flash.now[:alert] = "Please describe the survey you want to create."
      return render :new, status: :unprocessable_entity
    end

    @survey = SurveyGenerator.new.call(prompt)
    render partial: "survey", locals: { survey: @survey }
  rescue => e
    Rails.logger.error("[SurveyGenerator] #{e.class}: #{e.message}")
    flash.now[:alert] = "Generation failed: #{e.message}"
    render :new, status: :unprocessable_entity
  end
end
