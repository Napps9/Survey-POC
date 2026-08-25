require "test_helper"

# ContactDetail — the identified half of the contact feature's split — and the
# GDPR wall on Survey that keeps it from ever coexisting with demographic
# questions.
class ContactDetailTest < ActiveSupport::TestCase
  def org
    @org ||= Organisation.create!(name: "O", slug: "cd-#{SecureRandom.hex(3)}")
  end

  def survey(cards: [ { "type" => "yes_no", "text" => "Q", "options" => [ "Yes", "No" ] } ], contact: true)
    org.surveys.create!(
      title: "T", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ], cards: cards,
      contact_form_enabled: contact
    )
  end

  test "upsert_for! is one row per identity, updating in place" do
    s = survey
    a = ContactDetail.upsert_for!(survey: s, key_digest: "d1", fields: { "name" => "Ada", "email" => "ada@x.com" })
    b = ContactDetail.upsert_for!(survey: s, key_digest: "d1", fields: { "industry" => "Research" })

    assert_equal a.id, b.id
    b.reload
    assert_equal "Ada", b.name, "a partial update never blanks what was given before"
    assert_equal "Research", b.industry
    assert_equal 1, s.contact_details.count
  end

  test "upsert_for! refuses phantom rows and strips junk" do
    s = survey
    assert_nil ContactDetail.upsert_for!(survey: s, key_digest: "d2", fields: { "name" => "  ", "role" => "CEO" }),
               "all-blank (or unknown-field-only) details are not a contact"
    assert_equal 0, s.contact_details.count

    c = ContactDetail.upsert_for!(survey: s, key_digest: "d3", fields: { "name" => "  Bo  ", "email" => "x" * 500 })
    assert_equal "Bo", c.name
    assert_equal ContactDetail::MAX_FIELD, c.email.length
  end

  test "the GDPR wall: a contact form cannot join the neurodiversity question, whichever side moves second" do
    neuro_cards = [ { "type" => "yes_no", "text" => "Q", "options" => [ "Yes", "No" ] },
                    { "type" => "select_many", "text" => "N", "options" => [ "A", "B" ],
                      "demographic" => true, "demographic_key" => "neurodiversity" } ]

    # Neurodiversity first, contact second: the toggle is refused.
    s = survey(cards: neuro_cards, contact: false)
    s.contact_form_enabled = true
    assert_not s.valid?
    assert_match(/never both/, s.errors.full_messages.to_sentence)

    # Contact first, neurodiversity second: the card save is refused.
    s2 = survey
    s2.cards = neuro_cards
    assert_not s2.valid?
  end

  test "the wall is scoped: age, location, gender and heritage may sit beside a contact form" do
    cards = DemographicQuestions.append_to([ { "type" => "yes_no", "text" => "Q", "options" => [ "Yes", "No" ] } ]) +
            [ DemographicQuestions.optional_card("heritage").merge("cid" => "c_h1") ]
    s = survey(cards: cards, contact: true)
    assert s.valid?, s.errors.full_messages.to_sentence
    assert s.demographic_cards?
    assert_not s.neurodiversity_cards?
  end

  test "player_identity_active? covers the leaderboard and the contact gate" do
    s = survey(contact: false)
    assert_not s.player_identity_active?
    s.contact_form_enabled = true
    assert s.player_identity_active?
    s.assign_attributes(contact_form_enabled: false, tokenisation_enabled: true, leaderboard_enabled: true)
    assert s.player_identity_active?
  end

  test "contact rows go down with their survey" do
    s = survey
    ContactDetail.upsert_for!(survey: s, key_digest: "d9", fields: { "name" => "Zed" })
    s.destroy
    assert_equal 0, ContactDetail.where(survey_id: s.id).count
  end
end
