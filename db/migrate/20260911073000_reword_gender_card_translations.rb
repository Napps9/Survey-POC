class RewordGenderCardTranslations < ActiveRecord::Migration[8.1]
  # RewordGenderDemographicCard (20260910150000) rewrote the gender card's
  # `text` — the primary-language copy. A multilingual Verto also stores a
  # translation per secondary language under card["i18n"][locale], and
  # ApplicationHelper#localized_card prefers that over `text`, so a Verto
  # translated before the rewording still asks the old bare noun ("Genre",
  # "Geschlecht") to every respondent who plays it in a secondary language.
  # This finishes the job.
  #
  # Same snapshot as the earlier migration, repeated rather than referenced:
  # both have to keep meaning what they meant, and a shared constant is a
  # shared thing to drift. Here the locale is not inferred from the text at
  # all — an i18n entry is KEYED by its language, which is better evidence
  # than the words are.
  REWORDINGS = {
    "en"    => [ "Gender",          "What gender best describes you?" ],
    "nl"    => [ "Gender",          "Welk gender beschrijft jou het best?" ],
    "af"    => [ "Geslag",          "Watter geslag beskryf jou die beste?" ],
    "ar"    => [ "الجنس",            "ما الجنس الذي يصفك بشكل أفضل؟" ],
    "de"    => [ "Geschlecht",      "Welches Geschlecht beschreibt dich am besten?" ],
    "es"    => [ "Género",          "¿Qué género te describe mejor?" ],
    "fr"    => [ "Genre",           "Quel genre vous décrit le mieux ?" ],
    "he"    => [ "מגדר",             "איזה מגדר הכי מתאר אתכם?" ],
    "hi"    => [ "लिंग",              "कौन-सा लिंग आपका सबसे सही वर्णन करता है?" ],
    "id"    => [ "Jenis kelamin",   "Jenis kelamin mana yang paling menggambarkan Anda?" ],
    "it"    => [ "Genere",          "Quale genere ti descrive meglio?" ],
    "ja"    => [ "性別",              "あなたを最もよく表す性別はどれですか？" ],
    "ko"    => [ "성별",              "본인을 가장 잘 나타내는 성별은 무엇인가요?" ],
    "pl"    => [ "Płeć",            "Która płeć najlepiej Cię opisuje?" ],
    "pt"    => [ "Género",          "Com que género se identifica melhor?" ],
    "ru"    => [ "Пол",             "Какой пол лучше всего вас описывает?" ],
    "sn"    => [ "Vukama",          "Ndeipi jenda inokutsanangura zvakanyanya?" ],
    "st"    => [ "Bong",            "Ke bong bofe bo o hlalosang ka ho fetisisa?" ],
    "sw"    => [ "Jinsia",          "Ni jinsia gani inayokuelezea vizuri zaidi?" ],
    "tn"    => [ "Bong",            "Ke bong bofe jo bo go tlhalosang sentle thata?" ],
    "tr"    => [ "Cinsiyet",        "Sizi en iyi tanımlayan cinsiyet hangisi?" ],
    "uk"    => [ "Стать",           "Яка стать найкраще вас описує?" ],
    "vi"    => [ "Giới tính",       "Giới tính nào mô tả bạn đúng nhất?" ],
    "xh"    => [ "Isini",           "Sesiphi isini esikuchaza kakuhle?" ],
    "zu"    => [ "Ubulili",         "Yibuphi ubulili obukuchaza kangcono?" ]
  }.freeze

  # en-US has no entry of its own and is read through "en" — this question
  # spells identically in both, which is why the generated en-US.yml carries
  # the same string.
  ALIASES = { "en-us" => "en" }.freeze

  def up
    Survey.reset_column_information

    Survey.where.not(cards: nil).find_each(batch_size: 100) do |survey|
      changed = false

      updated = Array(survey.cards).map do |card|
        next card unless gender_card?(card) && card["i18n"].is_a?(Hash)

        touched = false
        i18n = card["i18n"].each_with_object({}) do |(locale, entry), out|
          out[locale] = entry
          next unless entry.is_a?(Hash)

          pair = rewording_for(locale)
          next unless pair && entry["text"].to_s == pair.first

          out[locale] = entry.merge("text" => pair.last)
          touched     = true
        end
        next card unless touched

        changed = true
        card.merge("i18n" => i18n)
      end

      survey.update_column(:cards, updated) if changed
    end
  end

  def down
    # Copy-only backfill, like the migration it completes: the old bare-noun
    # wording isn't something the app would ship again.
  end

  private

  # The pair for an i18n key, tolerating the shapes a stored locale key comes
  # in: "fr", "en-US" (aliased), "pt-BR" (region stripped to its language).
  def rewording_for(locale)
    key = locale.to_s.downcase
    REWORDINGS[locale.to_s] || REWORDINGS[ALIASES[key]] || REWORDINGS[key.split("-").first]
  end

  # Identical guard to RewordGenderDemographicCard — the tail's gender card
  # across both card generations, never the opt-in Heritage card (also a
  # demographic multiple_choice, which is why it carries a key).
  def gender_card?(card)
    return false unless card.is_a?(Hash) && card["demographic"] && card["type"] == "multiple_choice"

    key = card["demographic_key"].to_s
    key.empty? || key == "gender"
  end
end
