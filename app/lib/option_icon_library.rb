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
