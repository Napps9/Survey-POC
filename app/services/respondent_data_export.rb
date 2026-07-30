# Everything the platform holds about one respondent, for a GDPR subject access
# request (Article 15 / 20), plus the erasure that answers Article 17.
#
# Deliberately NOT built on ResultsExport. That produces the creator's analysis
# view — one row per respondent, one column per question, question columns only.
# A subject access request has to be *complete*: the demographics, the consent
# record, the derived region, the device and language, the timings and the quiz
# and token scoring all count as data held about that person, and none of them
# appear in the results export.
#
# Respondents are found by session token or, where the creator enabled
# respondent codes, by the code itself — which is matched against its HMAC
# digest, since the plaintext is never stored. A respondent who has neither
# cannot be identified: the session token lives in sessionStorage and is gone
# once the tab closes. That limit is real and documented in
# docs/DATA_RETENTION.md rather than papered over.
class RespondentDataExport
  class << self
    # Responses belonging to one respondent of `survey`. A respondent code can
    # match SEVERAL rows — that's the point of the feature, it links a person
    # across waves — so this always returns a relation.
    def lookup(survey:, session_token: nil, respondent_code: nil)
      if respondent_code.present?
        digest = survey.respondent_code_digest(respondent_code)
        return survey.responses.none if digest.blank?

        survey.responses.where(respondent_code_digest: digest)
      elsif session_token.present?
        survey.responses.where(session_token: session_token.to_s.strip)
      else
        survey.responses.none
      end
    end

    def call(survey:, responses:)
      new(survey: survey, responses: responses).call
    end
  end

  def initialize(survey:, responses:)
    @survey    = survey
    @responses = responses
  end

  def call
    {
      "verto"      => { "title" => @survey.title.presence || @survey.theme.presence, "id" => @survey.id },
      "exported_at" => Time.current.utc.iso8601,
      "notes"      => [
        "This file contains every field stored about this respondent.",
        "Answers are keyed by the question they were given, in the order shown.",
        "A respondent code is stored only as a one-way hash and cannot be reversed."
      ],
      "responses"  => @responses.map { |r| response_hash(r) }
    }
  end

  private

  def response_hash(response)
    {
      "response_id"    => response.id,
      "session_token"  => response.session_token,
      "status"         => response.status,
      "started_at"     => response.started_at&.utc&.iso8601,
      "completed_at"   => response.completed_at&.utc&.iso8601,
      "created_at"     => response.created_at.utc.iso8601,
      "duration_seconds" => response.duration_seconds,
      "language"       => response.locale,
      "device"         => response.device_kind,
      "demographics"   => {
        "birth_year" => response.demographic_birth_year,
        "gender"     => response.demographic_gender,
        "region"     => response.region_label,
        "country"    => response.region_country
      }.compact,
      "consent"        => {
        "agreed_at"   => response.consent_agreed_at&.utc&.iso8601,
        "declined_at" => response.consent_declined_at&.utc&.iso8601,
        "agreed_to"   => response.consent_text_snapshot
      }.compact,
      "respondent_code" => respondent_code_note(response),
      "scoring"        => scoring(response),
      "answers"        => answers(response)
    }.compact
  end

  def respondent_code_note(response)
    return nil if response.respondent_code_digest.blank?

    { "linked" => true,
      "note"   => "Stored as a one-way hash so the code itself is not held. " \
                  "It links this person's responses to this Verto only." }
  end

  def scoring(response)
    data = {}
    data["quiz_score"]   = response.score     if response.score.present?
    data["quiz_max"]     = response.quiz_max  if response.quiz_max.present?
    data["token_totals"] = response.token_totals if response.token_totals.present?
    data.presence
  end

  # Answers are stored keyed by CARD INDEX, so they're only meaningful next to
  # the deck. Emitted with the question text so the file makes sense to the
  # person receiving it rather than being a bag of numbered values.
  def answers(response)
    stored = response.answers
    return [] unless stored.is_a?(Hash)

    Array(@survey.cards).each_with_index.filter_map do |card, index|
      next unless card.is_a?(Hash)

      answer = stored[index.to_s]
      next unless answer.is_a?(Hash)

      value = answer["value"]
      next if value.nil? || (value.respond_to?(:empty?) && value.empty?)

      { "question" => card["text"].to_s,
        "type"     => card["type"].to_s,
        "answer"   => value,
        "other"    => answer["other"].presence }.compact
    end
  end
end
