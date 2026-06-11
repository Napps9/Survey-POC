org = Organisation.find_or_create_by!(slug: "playverto") do |o|
  o.name = "Playverto"
end

# Create-only: never reset the password of an existing admin (this file used
# to run on every production boot and silently reverted password changes).
user = User.find_or_create_by!(email_address: "admin@playverto.com") do |u|
  u.name     = "Admin"
  u.password = ENV.fetch("SEED_ADMIN_PASSWORD", "changeme123456")
end

Membership.find_or_create_by!(user: user, organisation: org) do |m|
  m.role = "admin"
end

puts "Seeded: org=#{org.name}, user=#{user.email_address}"
