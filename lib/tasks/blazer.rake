namespace :blazer do
  desc "Create or refresh the starter Blazer queries from BlazerStarterQueries"
  task sync_starter_queries: :environment do
    n = BlazerStarterQueries.resync!
    puts "Blazer starter queries synced (#{n} created/updated)."
  end
end

namespace :organisations do
  desc "Exclude an organisation from the Blazer dashboards (mark internal) by slug"
  task :mark_internal, [ :slug ] => :environment do |_task, args|
    abort "Usage: bin/rails 'organisations:mark_internal[org-slug]'" if args[:slug].blank?
    org = Organisation.find_by(slug: args[:slug]) || abort("No organisation with slug #{args[:slug].inspect}.")
    org.update!(internal: true)
    puts "#{org.name} (#{org.slug}) is now internal — excluded from the Blazer dashboards."
  end

  desc "Re-include a previously-excluded organisation in the Blazer dashboards by slug"
  task :unmark_internal, [ :slug ] => :environment do |_task, args|
    abort "Usage: bin/rails 'organisations:unmark_internal[org-slug]'" if args[:slug].blank?
    org = Organisation.find_by(slug: args[:slug]) || abort("No organisation with slug #{args[:slug].inspect}.")
    org.update!(internal: false)
    puts "#{org.name} (#{org.slug}) is no longer internal."
  end
end
