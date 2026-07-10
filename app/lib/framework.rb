# Loads the Awareness / Intention / Agency competency taxonomy and the
# enabling-condition layer from config/competencies.yml.
#
# This is the single source of truth shared by Ruby (the generator tool
# schemas + prompts, the "Why" tab badges) and JavaScript (type_panel_controller
# reads the same data via a JSON blob emitted by surveys/show.html.erb). It
# grounds Playverto's reading of the OECD "Education for Human Flourishing"
# framework — Acting in the world (agency): identify purpose, develop intent,
# act on it.
module Framework
  module_function

  # All competencies, in YAML (activation-sequence) order.
  # Hash<String, Hash<String,Object>> keyed by slug.
  def competencies
    COMPETENCIES
  end

  # All enabling conditions, in YAML order.
  def conditions
    CONDITIONS
  end

  # Metadata for one competency, String keys ("label", "blurb", "accent").
  # Returns an empty hash for unknown keys so callers can safely chain.
  def competency(key)
    COMPETENCIES[key.to_s] || {}
  end

  def condition(key)
    CONDITIONS[key.to_s] || {}
  end

  def competency?(key)
    COMPETENCY_KEYS.include?(key.to_s)
  end

  def condition?(key)
    CONDITION_KEYS.include?(key.to_s)
  end

  # JSON blob emitted into the editor page so the JS controller can label the
  # Why-tab badges without a network round-trip.
  def to_json(*)
    { "competencies" => COMPETENCIES, "conditions" => CONDITIONS }.to_json
  end

  DATA = YAML.load_file(Rails.root.join("config/competencies.yml")).freeze
  COMPETENCIES = DATA.fetch("competencies").freeze
  CONDITIONS   = DATA.fetch("conditions").freeze
  COMPETENCY_KEYS = COMPETENCIES.keys.freeze
  CONDITION_KEYS  = CONDITIONS.keys.freeze
end
