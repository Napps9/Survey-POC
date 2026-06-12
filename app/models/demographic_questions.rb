# Every Verto ends with the same three set demographic questions, appended
# automatically at creation (generate, PDF import). They give every Verto a
# comparable demographic tail — birth year, location, gender — powering the
# research collective across the platform. Cards carry "demographic" => true
# so they're identifiable downstream and never appended twice.
module DemographicQuestions
  CARDS = [
    { "type" => "open_ended", "input" => "date", "text" => "When were you born?",
      "demographic" => true },
    { "type" => "open_ended", "text" => "Where do you live?",
      "description" => "Country or city.", "demographic" => true },
    { "type" => "multiple_choice", "text" => "Gender",
      "options" => [ "Male", "Female", "Prefer not to say" ], "demographic" => true }
  ].freeze

  def self.cards
    CARDS.map(&:dup)
  end

  def self.append_to(cards)
    list = Array(cards)
    return list if list.any? { |c| c.is_a?(Hash) && c["demographic"] }
    list + cards()
  end
end
