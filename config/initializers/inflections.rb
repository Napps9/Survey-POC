# Be sure to restart your server when you modify this file.

# Add new inflection rules using the following format. Inflections
# are locale specific, and you may define rules for as many different
# locales as you wish. All of these examples are active by default:
# ActiveSupport::Inflector.inflections(:en) do |inflect|
#   inflect.plural /^(ox)$/i, "\\1en"
#   inflect.singular /^(ox)en/i, "\\1"
#   inflect.irregular "person", "people"
#   inflect.uncountable %w( fish sheep )
# end

# These inflection rules are supported but not enabled by default:
# ActiveSupport::Inflector.inflections(:en) do |inflect|
#   inflect.acronym "RESTful"
# end

# Rails' default -ve/-ves rule (for knife/knives, wife/wives, life/lives)
# over-matches "waves": singularize("waves") comes back "wafe" without this,
# which breaks `has_many :survey_waves` (Survey#survey_waves tries to
# resolve a SurveyWafe model). "wave" isn't one of the -ife/-ives words the
# built-in rule is actually meant for, so it gets its own irregular entry
# instead of a broader regex change that could affect other words.
ActiveSupport::Inflector.inflections(:en) do |inflect|
  inflect.irregular "wave", "waves"
end
