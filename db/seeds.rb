org = Organisation.find_or_create_by!(slug: "playverto") do |o|
  o.name = "Playverto"
end

user = User.find_or_initialize_by(email_address: "admin@playverto.com")
user.name     = "Admin"
user.password = "changeme123456"
user.save!

Membership.find_or_create_by!(user: user, organisation: org) do |m|
  m.role = "admin"
end

puts "Seeded: org=#{org.name}, user=#{user.email_address}"

# Demo data for the staging environment. Gated behind SEED_DEMO=1 so
# production (no env var) is unchanged. All operations idempotent.
if ENV["SEED_DEMO"] == "1"
  demo_org = Organisation.find_or_create_by!(slug: "demo-co") do |o|
    o.name = "Demo Co"
  end

  demo_user = User.find_or_initialize_by(email_address: "demo@playverto.com")
  demo_user.name     = "Demo Owner"
  demo_user.password = "demopass123456"
  demo_user.save!

  Membership.find_or_create_by!(user: demo_user, organisation: demo_org) do |m|
    m.role = "admin"
  end

  demo_cards = [
    { "type" => "welcome_card",
      "text" => "Welcome to the Playverto demo" },
    { "type" => "multiple_choice",
      "text" => "How did you hear about us?",
      "options" => [ "Friend", "Search", "Social media" ] },
    { "type" => "rating",
      "text" => "How easy was getting started?",
      "options" => [ "Hard", "OK", "Easy" ] },
    { "type" => "nps",
      "text" => "How likely are you to recommend us?",
      "options" => [ "0", "3", "5", "7", "10" ] },
    { "type" => "open_ended",
      "text" => "What's one thing we should improve?" }
  ]

  demo_survey = Survey.find_or_initialize_by(
    organisation: demo_org,
    title: "Onboarding feedback (demo)"
  )
  demo_survey.description    ||= "Seeded demo Verto — safe to play with."
  demo_survey.cards            = demo_cards
  demo_survey.default_locale ||= "en"
  demo_survey.publish_token  ||= SecureRandom.urlsafe_base64(18)
  demo_survey.published_at   ||= Time.current
  demo_survey.save!

  puts "Seeded demo: org=#{demo_org.name}, user=#{demo_user.email_address}, " \
       "survey=#{demo_survey.title} (/play/#{demo_survey.publish_token})"
end
