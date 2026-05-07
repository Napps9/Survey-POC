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
