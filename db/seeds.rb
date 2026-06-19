org = Organisation.find_or_create_by!(slug: "playverto") do |o|
  o.name = "Playverto"
end

# Only seed an admin when a password is explicitly supplied — never bake in a
# default credential. This file runs on initial production DB setup (the Render
# start command runs `db:prepare`), so a hardcoded password would create a
# publicly-known admin login. Set SEED_ADMIN_PASSWORD (and optionally
# SEED_ADMIN_EMAIL) to seed an admin; otherwise only the org is created.
#
# Create-only: an existing admin's password is never reset (this file used to
# run on every production boot and silently reverted password changes).
admin_password = ENV["SEED_ADMIN_PASSWORD"].presence

if admin_password
  email = ENV.fetch("SEED_ADMIN_EMAIL", "admin@playverto.com")
  user  = User.find_or_create_by!(email_address: email) do |u|
    u.name     = "Admin"
    u.password = admin_password
  end

  Membership.find_or_create_by!(user: user, organisation: org) do |m|
    m.role = "admin"
  end

  puts "Seeded: org=#{org.name}, admin=#{user.email_address}"
else
  puts "Seeded: org=#{org.name}. Set SEED_ADMIN_PASSWORD to also seed an admin user."
end

# Internal BI: starter Blazer queries for VertoNow staff (idempotent).
load Rails.root.join("db/seeds/blazer_starter_queries.rb")
