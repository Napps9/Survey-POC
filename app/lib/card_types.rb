# Loads the canonical card-type metadata from config/card_types.yml.
#
# This is the single source of truth shared by Ruby (helpers, views) and
# JavaScript (type_panel_controller reads the same data via a JSON blob
# emitted by surveys/show.html.erb).
module CardTypes
  module_function

  # All entries, in YAML order. Returns an Array<[String, Hash<String,Object>]>.
  def all
    DATA
  end

  # Hash for one type, with String keys (e.g. "badge", "eyebrow"). Returns
  # an empty hash for unknown types so callers can safely chain `.dig`.
  def meta(type)
    DATA_BY_KEY[type.to_s] || {}
  end

  def eyebrow(type)
    meta(type)["eyebrow"].to_s
  end

  def badge(type)
    meta(type)["badge"].to_s
  end

  def badge_css(type)
    meta(type)["badge_css"].to_s
  end

  # Types gated behind a feature flag: hidden from the picker and the AI
  # generator unless their env flag is enabled. Lets the code ship dormant.
  FLAGGED = {}.freeze

  # Whether a card type is currently available. Non-flagged types are always on;
  # flagged types require their env flag (default off).
  def enabled?(type)
    env = FLAGGED[type.to_s]
    return true unless env
    ActiveModel::Type::Boolean.new.cast(ENV[env]) || false
  end

  # Types that should appear in the in-editor answer-type picker.
  def pickable
    DATA.select { |_key, attrs| attrs["pickable"] }
  end

  # JSON blob emitted into the editor page so the JS controller has the
  # same data without round-tripping the network. Keyed by type slug.
  def to_json
    DATA_BY_KEY.to_json
  end

  DATA = begin
    raw = YAML.load_file(Rails.root.join("config/card_types.yml"))
    raw.to_a # preserve YAML order
  end.freeze

  DATA_BY_KEY = DATA.to_h.freeze
end
