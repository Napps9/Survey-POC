org = Organisation.find_or_create_by!(slug: "playverto") do |o|
  o.name = "Playverto"
end

user = User.find_or_create_by!(email_address: "admin@playverto.com") do |u|
  u.name     = "Admin"
  u.password = "changeme123"
end

Membership.find_or_create_by!(user: user, organisation: org) do |m|
  m.role = "admin"
end

puts "Seeded: org=#{org.name}, user=#{user.email_address}"
