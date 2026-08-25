class ChromeFollowsVertoLanguageByDefault < ActiveRecord::Migration[8.1]
  # The player's chrome — Back/Next, the required hint, the thank-you screen
  # and the CONSENT GATE — followed the visitor's browser Accept-Language,
  # while the cards followed the Verto. On a Verto that does not even offer
  # the visitor's language that produced a German consent box over English
  # questions, and an <html lang="de"> the content flatly contradicts.
  # Reported from the field: "the Consent Box for Age and Residence still in
  # German" — player.consent_default_text names a Geburtsdatum and a Wohnort,
  # which is exactly the age and residence in that report.
  #
  # The Verto's language is the default now.
  #
  # A default alone would fix nothing that already exists: column defaults
  # apply to INSERTs, and every live Verto carries a stored false. They are
  # backfilled. That does overwrite a creator who chose false deliberately —
  # accepted knowingly, because a stored false is indistinguishable from
  # never having touched an opt-in that shipped off, and every report of this
  # is from the second group. The setting stays, so anyone who wants the
  # respondent's own language can turn it back off.
  class Survey < ActiveRecord::Base; end

  def up
    change_column_default :surveys, :chrome_follows_verto_language, from: false, to: true
    Survey.where(chrome_follows_verto_language: false)
          .update_all(chrome_follows_verto_language: true)
  end

  def down
    change_column_default :surveys, :chrome_follows_verto_language, from: true, to: false
  end
end
