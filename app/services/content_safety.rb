# Keeps Verto imagery PG and age-appropriate to the Verto.
#
# The Pexels API has no server-side safe-search, so we guard both ends of every
# image/video lookup (AssetPopulator auto-populate + the editor media picker):
#
#   1. scrub_query — strip unsafe/age-inappropriate words from the search terms
#      so we never *ask* for that content in the first place.
#   2. safe? — check a returned item's description (Pexels `alt`) and drop any
#      that slips through a clean-looking query.
#
# GENERAL terms are blocked for every Verto (adult/suggestive, graphic
# violence, weapons, hard drugs). YOUNG terms are additionally blocked when the
# Verto's audience skews young (kids/teen) — legal-but-mature themes that
# aren't age-appropriate for children.
module ContentSafety
  GENERAL = %w[
    nude nudity naked topless nsfw sexy sexual sex erotic erotica sensual
    lingerie underwear bikini thong porn pornographic fetish boudoir seductive
    provocative cleavage bdsm strip stripper twerk hentai
    gore gory blood bloody corpse dead death murder gun guns rifle pistol
    firearm weapon weapons knife stabbing violence violent gunshot war combat
    terrorist beheading
    cocaine heroin meth methamphetamine marijuana cannabis weed drug drugs
    syringe overdose narcotics
  ].to_set.freeze

  YOUNG = %w[
    alcohol alcoholic beer wine whiskey whisky vodka rum tequila liquor cocktail
    cocktails drunk drinking bar pub nightclub
    cigarette cigarettes cigar smoking smoke vape vaping tobacco hookah shisha
    gambling casino poker betting lottery
    tattoo tattoos piercing
  ].to_set.freeze

  YOUNG_BUCKETS = %w[kids teen].freeze

  # ── Brand-neutrality suppression — NOT a safety list ─────────────────────
  # These subjects are legal and often photogenic, but visually charged:
  # protest/activism imagery must never be AUTO-applied to a Verto whose
  # theme doesn't invoke it (a creator can still pick anything by hand in
  # the editor). Kept deliberately to the protest-VISUAL core that caused
  # the bug — crowds, placards, marches.
  #
  # HELD OUT on purpose, pending an explicit product decision (widening this
  # list is an editorial call, not an engineering default — see the pinned
  # "abstract political vocabulary" test): justice, equality, rights,
  # discrimination, racism, antiracism, sexism, feminism, politics, vote,
  # election, referendum, brexit, solidarity, revolution, resistance,
  # unrest, "pride parade", "trade union", "far right", "far left",
  # "me too movement".
  #
  # EXCLUDED for ambiguity (false positives outweigh the risk): police,
  # policing, banner, flag, movement, campaign, strike, striker, megaphone.
  CHARGED = %w[
    protest protests protester protesters protestor protestors protesting
    march marches marcher marchers
    rally rallies riot riots rioting rioter rioters
    demonstration demonstrations demonstrator demonstrators
    placard placards picket pickets picketing
  ].to_set.freeze

  # Named protest movements whose individual words are benign ("black",
  # "lives", "matter") — matched as downcased substrings.
  CHARGED_PHRASES = [
    "black lives matter", "extinction rebellion", "just stop oil"
  ].freeze

  # Extra words that signal deliberate creator intent in a THEME without
  # themselves being suppressed from imagery: a theme saying "activism"
  # should unlock protest photos even though "activism" never appears in
  # protest alt text.
  CHARGED_TOPIC = %w[activism activist activists].to_set.freeze

  module_function

  # The active blocklist for a set of age buckets (see AssetPopulator.age_buckets).
  def blocklist(age_buckets = [])
    (Array(age_buckets) & YOUNG_BUCKETS).any? ? (GENERAL | YOUNG) : GENERAL
  end

  def words(text)
    text.to_s.downcase.scan(/[a-z]+/)
  end

  # True when the text (a query, or a Pexels `alt` description) contains no
  # blocked term for this audience.
  def safe?(text, age_buckets = [])
    bl = blocklist(age_buckets)
    words(text).none? { |w| bl.include?(w) }
  end

  # A cleaned search query with blocked terms removed. May come back empty when
  # every term was blocked — callers treat that as "don't search / fall back".
  def scrub_query(query, age_buckets = [])
    bl = blocklist(age_buckets)
    words(query).reject { |w| bl.include?(w) }.join(" ")
  end

  # True when the text (a Pexels `alt`, a video page slug, or a theme) names
  # a charged protest-visual subject — by word or by movement phrase.
  def charged?(text)
    t = text.to_s.downcase
    return true if CHARGED_PHRASES.any? { |phrase| t.include?(phrase) }
    words(text).any? { |w| CHARGED.include?(w) }
  end

  def neutral?(text)
    !charged?(text)
  end

  # Does this Verto's theme deliberately invoke the protest/activism topic?
  # If so, the neutrality suppression (and charged-term query stripping) is
  # switched off for the whole run — the creator's stated topic wins.
  def charged_theme?(theme_text)
    charged?(theme_text) || words(theme_text).any? { |w| CHARGED_TOPIC.include?(w) }
  end
end
