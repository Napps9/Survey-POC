class CommonQuestionSetsController < ApplicationController
  layout "fullscreen", only: [ :index, :new, :show, :results ]

  before_action :set_set, only: [ :show, :update, :destroy, :results, :add_question, :update_question, :destroy_question ]

  def index
    @kept_sets     = Current.organisation.common_question_sets.kept.recent.includes(:common_questions)
    @archived_sets = Current.organisation.common_question_sets.archived.recent.includes(:common_questions)

    @total_questions = @kept_sets.sum { |s| s.common_questions.size }
    set_ids = @kept_sets.map(&:id)
    attached_surveys = Current.organisation.surveys.kept.includes(:responses).select do |s|
      Array(s.cards).any? { |c| c.is_a?(Hash) && set_ids.include?(c["common_question_set_id"]) }
    end
    @vertos_using_count = attached_surveys.size
    @cq_response_count  = attached_surveys.sum { |s| s.responses.size }
  end

  def new
    @set = Current.organisation.common_question_sets.new(default_locale: Current.locale.to_s)
  end

  # Blank-create: name/theme/key_insight only. Questions are added on the show
  # page (each one runs through QuestionTypeClassifier on save).
  def create
    @set = Current.organisation.common_question_sets.new(set_params)
    if @set.save
      redirect_to common_question_set_path(@set), notice: "Common Questions set created. Add your first question below."
    else
      flash.now[:alert] = @set.errors.full_messages.to_sentence
      render :new, status: :unprocessable_entity
    end
  end

  # Generate-from-brief: ask Claude for 4-6 question texts based on theme +
  # key_insight, then run those texts through the classifier to assign types
  # and persist them as CommonQuestion rows.
  def generate
    name        = params[:name].to_s.strip
    theme       = params[:theme].to_s.strip
    key_insight = params[:key_insight].to_s.strip
    locale      = SupportedLocales.coerce(params[:default_locale].presence || Current.locale.to_s)

    if theme.empty? || key_insight.empty?
      flash.now[:alert] = "Tell us the theme and the key insight you're looking to gather — those two are required."
      @set = Current.organisation.common_question_sets.new(name: name, theme: theme, key_insight: key_insight, default_locale: locale)
      return render :new, status: :unprocessable_entity
    end

    draft = CommonQuestionGenerator.new.call(theme: theme, key_insight: key_insight, locale: locale)
    classified = QuestionTypeClassifier.new.call(
      questions: Array(draft["questions"]).map { |q| q["text"] },
      locale:    locale
    )

    if classified.empty?
      flash.now[:alert] = "We couldn't draft a set from that — try a clearer theme or key insight."
      @set = Current.organisation.common_question_sets.new(name: name, theme: theme, key_insight: key_insight, default_locale: locale)
      return render :new, status: :unprocessable_entity
    end

    set = nil
    CommonQuestionSet.transaction do
      set = Current.organisation.common_question_sets.create!(
        name:           name.presence || draft["name"].to_s.presence || "Common Questions",
        theme:          theme,
        key_insight:    key_insight,
        default_locale: locale
      )

      classified.each_with_index do |card, i|
        set.common_questions.create!(
          position:    i,
          text:        card["text"],
          description: card["description"],
          card_type:   card["type"],
          options:     Array(card["options"]).presence,
          allow_other: card["allow_other"] == true
        )
      end
    end

    redirect_to common_question_set_path(set), notice: "Drafted #{set.common_questions.size} questions. Edit any of them below before attaching this set to a Verto."
  rescue => e
    ErrorReporting.report("CommonQuestionGenerator", e)
    flash.now[:alert] = "We couldn't draft your set — #{e.message.first(180)}"
    @set = Current.organisation.common_question_sets.new(name: name, theme: theme, key_insight: key_insight, default_locale: locale)
    render :new, status: :unprocessable_entity
  end

  def show
    @affected_surveys = @set.surveys_using(Current.organisation.surveys.kept)
  end

  def update
    if @set.update(set_params)
      redirect_to common_question_set_path(@set), notice: "Updated."
    else
      flash.now[:alert] = @set.errors.full_messages.to_sentence
      render :show, status: :unprocessable_entity
    end
  end

  def destroy
    @set.archive!
    redirect_to common_question_sets_path, notice: "“#{@set.name}” deleted. Existing Vertos keep their attached snapshot."
  end

  # POST /common-question-sets/:id/add_question
  # Append a user-typed question to the set. Classification runs synchronously
  # so the user sees the assigned card type immediately.
  def add_question
    text = params[:text].to_s.strip
    if text.empty?
      return redirect_to common_question_set_path(@set), alert: "Type the question first."
    end

    classified = QuestionTypeClassifier.new.call(questions: [ text ], locale: @set.default_locale)
    card = classified.first

    if card.blank?
      return redirect_to common_question_set_path(@set), alert: "We couldn't classify that question — try rephrasing."
    end

    @set.common_questions.create!(
      text:        card["text"],
      description: card["description"],
      card_type:   card["type"],
      options:     Array(card["options"]).presence,
      allow_other: card["allow_other"] == true
    )

    redirect_to common_question_set_path(@set)
  rescue => e
    ErrorReporting.report("CommonQuestionSets#add_question", e)
    redirect_to common_question_set_path(@set), alert: "Couldn't add the question — #{e.message.first(180)}"
  end

  # PATCH /common-question-sets/:id/questions/:question_id
  def update_question
    question = @set.common_questions.find(params[:question_id])
    text     = params[:text].to_s.strip
    new_type = params[:card_type].to_s.strip

    if text.empty?
      return redirect_to common_question_set_path(@set), alert: "Question text can't be blank."
    end

    # If wording changed and no explicit type override, re-run the classifier
    # so the assigned type stays aligned with the question's new framing.
    if new_type.present? && SurveyGenerator::CARD_TYPES.include?(new_type)
      question.update!(text: text, card_type: new_type)
    elsif text != question.text
      classified = QuestionTypeClassifier.new.call(questions: [ text ], locale: @set.default_locale)
      card = classified.first
      if card.present?
        question.update!(
          text:        card["text"],
          description: card["description"],
          card_type:   card["type"],
          options:     Array(card["options"]).presence,
          allow_other: card["allow_other"] == true
        )
      else
        question.update!(text: text)
      end
    end

    redirect_to common_question_set_path(@set)
  rescue => e
    ErrorReporting.report("CommonQuestionSets#update_question", e)
    redirect_to common_question_set_path(@set), alert: "Couldn't update — #{e.message.first(180)}"
  end

  def destroy_question
    question = @set.common_questions.find(params[:question_id])
    question.destroy!
    redirect_to common_question_set_path(@set)
  end

  def results
    surveys = @set.surveys_using(Current.organisation.surveys)
    @per_question, @snapshot_variants, @total_surveys, @total_responses =
      CommonQuestionAggregator.new(@set, surveys).aggregate
  end

  private

  def set_set
    @set = Current.organisation.common_question_sets.find(params[:id])
  end

  def set_params
    params.permit(:name, :theme, :key_insight, :default_locale).tap do |p|
      p[:default_locale] = SupportedLocales.coerce(p[:default_locale]) if p[:default_locale].present?
    end
  end
end
