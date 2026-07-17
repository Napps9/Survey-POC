namespace :brand_assets do
  # Bulk-load a customer's brand kit into their account's asset library without
  # click-uploading each file. Run it where the target org's Active Storage
  # lives (the production container, so the images land on the persistent disk).
  #
  #   bin/rails "brand_assets:import[the-economist, https://example.com/kit.zip]"
  #   bin/rails "brand_assets:import[The Economist, ./tmp/economist]"   # a folder
  #
  # `org` matches by slug first, then name. `source` is a directory, a .zip, a
  # single image, or an http(s) URL to any of those. Safe to re-run: existing
  # filenames are skipped, and the same type/size/count limits as the UI apply.
  desc "Import a folder/zip/URL of images into an organisation's brand library: brand_assets:import[org, source]"
  task :import, [ :org, :source ] => :environment do |_t, args|
    org_ident = args[:org].to_s.strip
    source    = args[:source].to_s.strip
    if org_ident.empty? || source.empty?
      abort %(Usage: bin/rails "brand_assets:import[org_slug_or_name, source_dir_zip_or_url]")
    end

    org = Organisation.find_by(slug: org_ident) || Organisation.find_by(name: org_ident)
    abort "No organisation matching #{org_ident.inspect} (by slug or name)." unless org

    puts "Importing brand assets into #{org.name} (slug: #{org.slug})"
    puts "  source: #{source}"
    result = BrandAssetImporter.call(org: org, source: source)

    puts "  added: #{result.added.size}"
    result.added.each   { |fn|      puts "    + #{fn}" }
    result.skipped.each { |fn, why| puts "    · skip  #{fn} — #{why}" }
    result.errors.each  { |fn, why| puts "    ! error #{fn} — #{why}" }
    puts "Done: #{result.summary}. Library now holds #{org.assets.attachments.size} asset(s)."
  end
end
