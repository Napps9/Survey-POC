class RewordGenderDemographicCard < ActiveRecord::Migration[8.1]
  # The gender card in the demographic tail (DemographicQuestions::CARDS) used
  # to be a bare noun — "Gender" — sitting between two cards that ask a
  # question ("When were you born?", "Where do you live?"). It now asks one
  # too. New Vertos pick that up from the registry; every Verto that already
  # exists carries the old copy in its stored deck, so rewrite it here.
  #
  # Old and new copy are SNAPSHOTTED per locale rather than read from
  # DemographicQuestions or the locale files: a migration has to keep meaning
  # what it meant, and the next copy change would otherwise make this one
  # match nothing (or, worse, rewrite the wrong cards).
  #
  # Keyed by the locale the stored card is written IN, not by the Verto's
  # locale — every Verto used to get the English tail regardless of its
  # language (see DemographicQuestions.cards), so a French Verto may well hold
  # the English card. Matching the text is what identifies the language, and a
  # card is only ever rewritten into the language it is already in.
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

  # Three old texts are shared by two locales each — "Gender" (en, nl),
  # "Género" (es, pt), "Bong" (st, tn) — so the Verto's own locale is
  # consulted FIRST and the table is only scanned as a fallback. A Dutch Verto
  # holding "Gender" gets the Dutch question; an English one gets the English.
  # An en-US Verto has no entry of its own and falls through to "en", which is
  # the same copy either way — this question spells identically in both.
  def up
    Survey.reset_column_information

    Survey.where.not(cards: nil).find_each(batch_size: 100) do |survey|
      preferred = REWORDINGS[survey.default_locale.to_s]
      changed   = false

      updated = Array(survey.cards).map do |card|
        next card unless gender_card?(card)

        pair   = preferred if preferred && preferred.first == card["text"]
        pair ||= REWORDINGS.each_value.find { |old, _| old == card["text"] }
        next card unless pair

        changed = true
        card.merge("text" => pair.last)
      end

      survey.update_column(:cards, updated) if changed
    end
  end

  def down
    # Copy-only backfill: the old bare-noun wording isn't something the app
    # would ship again, and a Verto whose creator has since edited the card
    # must not be dragged back to it.
  end

  private

  # The tail's gender card, across both card generations — mirrors the guard in
  # lib/tasks/demographics.rake and PlayerController#sync_demographics_from_answers!:
  # the opt-in Heritage card is also a demographic multiple_choice, and carries
  # a key precisely so it never gets taken for this one.
  def gender_card?(card)
    return false unless card.is_a?(Hash) && card["demographic"] && card["type"] == "multiple_choice"

    key = card["demographic_key"].to_s
    key.empty? || key == "gender"
  end
end
