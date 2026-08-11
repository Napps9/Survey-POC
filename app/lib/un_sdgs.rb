# The 17 UN Sustainable Development Goals, as fixed by the 2030 Agenda
# (https://sdgs.un.org/goals). The numbering and titles are the UN's own and
# have not changed since 2015, so they live here as a frozen constant rather
# than in the database or the locale files: "SDG 13" is the same badge in every
# language, and the official goal titles are proper nouns, not UI chrome.
#
# Single authority for everything SDG-shaped: the classifier's tool schema and
# rubric, the display chips, and the backfill task all read from here.
module UnSdgs
  module_function

  TITLES = {
    1  => "No Poverty",
    2  => "Zero Hunger",
    3  => "Good Health and Well-being",
    4  => "Quality Education",
    5  => "Gender Equality",
    6  => "Clean Water and Sanitation",
    7  => "Affordable and Clean Energy",
    8  => "Decent Work and Economic Growth",
    9  => "Industry, Innovation and Infrastructure",
    10 => "Reduced Inequalities",
    11 => "Sustainable Cities and Communities",
    12 => "Responsible Consumption and Production",
    13 => "Climate Action",
    14 => "Life Below Water",
    15 => "Life on Land",
    16 => "Peace, Justice and Strong Institutions",
    17 => "Partnerships for the Goals"
  }.freeze

  NUMBERS = (1..17)

  # The official goal colours from the UN's SDG brand guidelines — fixed like
  # the titles, so goal 13 is the same green on every surface and in every
  # language. Mirrored in app/javascript/lib/un_sdgs.js for the source cards
  # the Ask Verto stream renders client-side; JsConstantParityTest keeps the
  # two copies in step.
  COLORS = {
    1  => "#E5243B",
    2  => "#DDA63A",
    3  => "#4C9F38",
    4  => "#C5192D",
    5  => "#FF3A21",
    6  => "#26BDE2",
    7  => "#FCC30B",
    8  => "#A21942",
    9  => "#FD6925",
    10 => "#DD1367",
    11 => "#FD9D24",
    12 => "#BF8B2E",
    13 => "#3F7E44",
    14 => "#0A97D9",
    15 => "#56C02B",
    16 => "#00689D",
    17 => "#19486A"
  }.freeze

  # "SDG 13" — the UN's own locale-independent shorthand, used verbatim on
  # every chip.
  def label(number)
    "SDG #{number}"
  end

  # The goal's official colour. Ask Verto's violet as the fallback, so an
  # unknown number degrades to the product hue rather than to unstyled.
  def color(number)
    COLORS.fetch(number.to_i, "#8B85FF")
  end

  # The official goal title, for tooltips. Empty string for an unknown number
  # so a view can interpolate without guarding.
  def title(number)
    TITLES[number.to_i].to_s
  end

  # "SDG 13 — Climate Action", for places with room for both.
  def label_with_title(number)
    "#{label(number)} — #{title(number)}"
  end

  # Whatever the model (or an old row) handed over, reduced to what the column
  # is allowed to hold: integers 1..17, deduplicated, ascending. The tool
  # schema's enum makes junk rare; this makes it unstorable.
  def sanitize(list)
    Array(list).map { |n| n.to_i }.select { |n| NUMBERS.cover?(n) }.uniq.sort
  end
end
