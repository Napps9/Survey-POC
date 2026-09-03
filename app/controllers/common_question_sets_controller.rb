class CommonQuestionSetsController < ApplicationController
  include ThrottlesAiSpend
  layout "fullscreen", only: [ :index, :new, :show, :results ]

  # #generate runs CommonQuestionGenerator plus QuestionTypeClassifier — two
  # Claude calls per request, on a form post (P0-4).
  throttle_ai to: 20, within: 1.hour, name: "ai-question-set", respond: :html, only: %i[ generate ]
  cap_ai_spend respond: :html, only: %i[ generate ]

  # Common Questions are content the same way a Verto's cards are: a viewer
  # can look at every set and its results, and can't start, change or remove
  # one. The list and detail pages hide the forms on the same answer.
  gate_verto_editing only: %i[ new create generate update destroy
                               add_question update_question destroy_question ]

  before_action :set_set, only: [ :show, :update, :destroy, :results, :add_question, :update_question, :destroy_question ]

  def index
    @kept_sets     = Current.organisation.common_question_sets.kept.recent.includes(:common_questions)
    @archived_sets = Current.organisation.common_question_sets.archived.recent.includes(:common_questions)

    @total_questions = @kept_sets.sum { |s| s.common_questions.size }
    set_ids = @kept_sets.map(&:id)

    # Which cards carry a set can only be answered by reading the cards JSON, so
    # the surveys themselves are still loaded — but without the report/summary
    # text columns, which this never looks at.
    attached_ids = Current.organisation.surveys.kept.without_report_text.filter_map do |s|
      s.id if Array(s.cards).any? { |c| c.is_a?(Hash) && set_ids.include?(c["common_question_set_id"]) }
    end

    @vertos_using_count = attached_ids.size
    # One COUNT, rather than eager-loading every response row of every attached
    # Verto — answers JSON and all — purely to call .size on them.
    @cq_response_count  = attached_ids.any? ? Response.where(survey_id: attached_ids).count : 0
  end

  def new
    @set = Current.organisation.common_question_sets.new(default_locale: Current.locale.to_s)
  end

  # Blank-create: name/theme/key_insight only. Questions are added on the show
  # page (each one runs through QuestionTypeClassifier on save).
  def create
    @set = Current.organisation.common_question_sets.new(set_params)
    if @set.save
      redirect_to common_question_set_path(@set), notice: t("flash.common_question_sets.created")
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
      flash.now[:alert] = t("flash.common_question_sets.theme_and_insight_required")
      @set = Current.organisation.common_question_sets.new(name: name, theme: theme, key_insight: key_insight, default_locale: locale)
      return render :new, status: :unprocessable_entity
    end

    draft = CommonQuestionGenerator.new.call(theme: theme, key_insight: key_insight, locale: locale)
    classified = QuestionTypeClassifier.new.call(
      questions: Array(draft["questions"]).map { |q| q["text"] },
      locale:    locale
    )

    if classified.empty?
      flash.now[:alert] = t("flash.common_question_sets.draft_empty")
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

    redirect_to common_question_set_path(set), notice: t("flash.common_question_sets.drafted", count: set.common_questions.size)
  rescue => e
    ErrorReporting.report("CommonQuestionGenerator", e)
    flash.now[:alert] = t("flash.common_question_sets.draft_failed", reason: e.message.first(180))
    @set = Current.organisation.common_question_sets.new(name: name, theme: theme, key_insight: key_insight, default_locale: locale)
    render :new, status: :unprocessable_entity
  end

  def show
    @affected_surveys = @set.surveys_using(Current.organisation.surveys.kept)
  end

  def update
    if @set.update(set_params)
      redirect_to common_question_set_path(@set), notice: t("flash.common_question_sets.updated")
    else
      flash.now[:alert] = @set.errors.full_messages.to_sentence
      render :show, status: :unprocessable_entity
    end
  end

  def destroy
    @set.archive!
    redirect_to common_question_sets_path, notice: t("flash.common_question_sets.deleted", name: @set.name)
  end

  # POST /common-question-sets/:id/add_question
  # Append a user-typed question to the set. Classification runs synchronously
  # so the user sees the assigned card type immediately.
  def add_question
    text = params[:text].to_s.strip
    if text.empty?
      return redirect_to common_question_set_path(@set), alert: t("flash.common_question_sets.question_text_missing")
    end

    classified = QuestionTypeClassifier.new.call(questions: [ text ], locale: @set.default_locale)
    card = classified.first

    if card.blank?
      return redirect_to common_question_set_path(@set), alert: t("flash.common_question_sets.classification_failed")
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
    redirect_to common_question_set_path(@set), alert: t("flash.common_question_sets.add_question_failed", reason: e.message.first(180))
  end

  # PATCH /common-question-sets/:id/questions/:question_id
  def update_question
    question = @set.common_questions.find(params[:question_id])
    text     = params[:text].to_s.strip
    new_type = params[:card_type].to_s.strip

    if text.empty?
      return redirect_to common_question_set_path(@set), alert: t("flash.common_question_sets.question_text_blank")
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
    redirect_to common_question_set_path(@set), alert: t("flash.common_question_sets.update_question_failed", reason: e.message.first(180))
  end

  def destroy_question
    question = @set.common_questions.find(params[:question_id])
    question.destroy!
    redirect_to common_question_set_path(@set)
  end

  def results
    # without_report_text: the aggregator reads cards and responses, never the
    # multi-KB AI report/summary columns those Vertos may be carrying.
    surveys = @set.surveys_using(Current.organisation.surveys.without_report_text)
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
