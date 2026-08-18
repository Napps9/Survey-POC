# Deterministic label -> icon lookup for the "select" answer types'
# per-option tiles (multiple_choice / select_many / select_one_grid /
# select_many_grid). Backs config/option_icons.yml + the SVGs under
# app/assets/images/option-icons/.
#
# Unlike AssetPopulator (fuzzy, scored, survey-theme matching against a
# curated photo pool), this is an exact keyword lookup against a small
# bundled icon set — deliberately conservative so an option's own text never
# picks up a surprising icon. Purely presentational: computed at render time,
# nothing is persisted, so it needs no sanitizer and no editor/autosave
# wiring (mirrors how the choice-bg-N gradient tile is already computed at
# render time rather than stored).
module OptionIconLibrary
  module_function

  ICONS_DIR = Rails.root.join("app/assets/images/option-icons").freeze

  # [{ "file" => "basketball.svg", "keywords" => ["basketball"] }, ...],
  # loaded once (like CardTypes::DATA) — adding a new icon needs a server
  # restart in dev, same tradeoff config/card_types.yml already accepts.
  DATA = YAML.load_file(Rails.root.join("config/option_icons.yml")).freeze

  # keyword (normalised) => filename, flattened from DATA for O(1) lookup.
  KEYWORD_TO_FILE = DATA.each_with_object({}) do |entry, h|
    Array(entry["keywords"]).each { |kw| h[kw.to_s.downcase.strip] = entry["file"] }
  end.freeze

  # Inline SVG markup (html_safe) for an option label, or nil when nothing
  # matches. Decorative — the option's own text already carries the meaning —
  # so the markup is stripped of id/title and marked aria-hidden.
  def svg_for(label)
    file = file_for(label)
    file && inline_svg(file)
  end

  # ── Emoji fallback ───────────────────────────────────────────────────────
  # A selection answer should never show an empty tile — a bare gradient reads
  # as unfinished next to rows that did match. When no icon, no creator-picked
  # emoji and no label emoji filled the tile, one comes from here: a curated
  # keyword match if there is one, else a neutral shape cycled by position so
  # a deck's options stay visually distinct without asserting any meaning.
  EMOJI_DATA = YAML.load_file(Rails.root.join("config/option_emojis.yml")).freeze

  EMOJI_KEYWORDS = EMOJI_DATA.fetch("keywords", {}).to_h { |k, v| [ k.to_s.downcase.strip, v.to_s ] }.freeze
  EMOJI_FALLBACKS = Array(EMOJI_DATA.fetch("fallbacks", [])).map(&:to_s).freeze

  # Words that carry no subject of their own. Dropped before matching so a
  # leading article can't hide an otherwise perfect keyword — "A colleague"
  # matched nothing while "colleague" would have.
  EMOJI_STOPWORDS = %w[a an the of my our your their this that and or to for in
                       on at by with from is are was were be been].freeze

  def emoji_for(label, index = 0)
    norm = normalize(label)
    return nil if EMOJI_FALLBACKS.empty?

    keyword_emoji(norm) || EMOJI_FALLBACKS[index.to_i % EMOJI_FALLBACKS.length]
  end

  # The whole label first, then progressively shorter runs of its words, then
  # single words — longest match wins, so "social media" beats "media" and
  # "email newsletter" beats "email".
  #
  # This used to be an exact hash lookup on the whole normalised label, which
  # meant a keyword only ever matched a label that was ONLY that keyword. Every
  # option on a "how did you hear about us?" card ("Social media", "Word of
  # mouth", "Email newsletter", "A colleague", "Online search", "Previous
  # attendee") therefore fell through to the coloured-shape fallback — reported
  # 18 Aug as "auto emoji picker only picks these shapes".
  def keyword_emoji(norm)
    # The whole label as written, first. Some catalogue keys contain stopwords
    # themselves ("buy a home"), and stripping them before this would stop those
    # keys ever matching the label they were written for.
    exact = EMOJI_KEYWORDS[norm] || EMOJI_KEYWORDS[norm.sub(/s\z/, "")]
    return exact if exact

    words = norm.split(" ") - EMOJI_STOPWORDS
    return nil if words.empty?

    words.length.downto(1) do |span|
      words.each_cons(span) do |run|
        phrase = run.join(" ")
        hit = EMOJI_KEYWORDS[phrase] || EMOJI_KEYWORDS[phrase.sub(/s\z/, "")]
        return hit if hit
      end
    end
    nil
  end

  # ── Explicit picks (per-option `option_styles.icon`) ─────────────────────
  # Icons are addressed by their file basename (e.g. "basketball"), which is
  # what the editor's icon picker stores and the sanitiser validates.

  def ids
    @ids ||= DATA.map { |entry| File.basename(entry["file"], ".svg") }.freeze
  end

  def valid_id?(id)
    ids.include?(id.to_s)
  end

  def svg_by_id(id)
    valid_id?(id) ? inline_svg("#{id}.svg") : nil
  end

  def file_for(label)
    norm = normalize(label)
    return nil if norm.empty?
    KEYWORD_TO_FILE[norm] || KEYWORD_TO_FILE[norm.sub(/s\z/, "")]
  end

  def normalize(label)
    label.to_s.downcase.strip.gsub(/[^a-z0-9\s]/, "").gsub(/\s+/, " ").strip
  end

  # Raw file contents read once per filename and memoised for the process
  # lifetime (same direct-file-read approach AssetPopulator uses for its
  # manifest). id/data-name/<title> are stripped so the same icon can render
  # more than once on a page without duplicate DOM ids.
  def inline_svg(file)
    @svg_cache ||= {}
    @svg_cache[file] ||= begin
      raw = File.read(ICONS_DIR.join(file))
      raw = raw.sub(%r{<title>.*?</title>}m, "")
      raw = raw.gsub(/\s(?:id|data-name)="[^"]*"/, "")
      raw = raw.sub(/<svg\b/, '<svg class="choice-icon-svg" aria-hidden="true" focusable="false"')
      raw.html_safe
    end
  end
end
