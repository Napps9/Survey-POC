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
end
