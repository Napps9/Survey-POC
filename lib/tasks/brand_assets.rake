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

  # Brand-library tiles render a preprocessed :thumb variant, built by a job at
  # upload time. Assets uploaded BEFORE that variant was declared have no thumb,
  # so the first person to open their library still pays for a lazy libvips
  # transform per tile — the exact spike preprocessing exists to avoid.
  #
  # This queues the missing ones. Deliberately a task rather than a migration or
  # a boot hook: it's a bulk run of native image transforms, and when that
  # happens on a memory-bounded instance should be somebody's decision.
  #
  #   bin/rails brand_assets:backfill_thumbs            # every organisation
  #   bin/rails "brand_assets:backfill_thumbs[acme]"    # one, by slug or name
  desc "Queue the preprocessed thumbnail for brand assets that predate it: brand_assets:backfill_thumbs[org]"
  task :backfill_thumbs, [ :org ] => :environment do |_t, args|
    ident = args[:org].to_s.strip
    scope =
      if ident.empty?
        Organisation.all
      else
        org = Organisation.find_by(slug: ident) || Organisation.find_by(name: ident)
        abort "No organisation matching #{ident.inspect} (by slug or name)." unless org
        Organisation.where(id: org.id)
      end

    # The same call ActiveStorage makes for a preprocessed variant on upload
    # (Attachment#transform_variants_later), so a backfilled thumb is built
    # exactly the way a freshly uploaded one is.
    transformations = Organisation.reflect_on_attachment(:assets).named_variants[:thumb].transformations

    queued = skipped = 0
    scope.find_each do |organisation|
      organisation.assets.attachments.each do |attachment|
        blob = attachment.blob
        # Vector art has no variant to build, and anything already processed
        # would only be re-transformed for nothing.
        next skipped += 1 unless blob.variable?
        next skipped += 1 if blob.variant(transformations).send(:processed?)

        blob.preprocessed(transformations)
        queued += 1
      rescue => e
        warn "  ! #{organisation.slug} / #{blob&.filename} — #{e.class}: #{e.message}"
      end
    end

    puts "Queued #{queued} thumbnail transform(s); skipped #{skipped} (vector, or already built)."
  end

  # Active Storage serves a blob at /rails/active_storage/…/<filename>, and
  # Survey::ACTIVE_STORAGE_IMAGE_URL only accepts such a path when it ends in a
  # real image extension. The branding page validated uploads by content type
  # and stored them under their original name, so an asset called "logo" or
  # "holiday.jfif" was pickable in the editor but dropped from the card on save
  # — the creator saw "an image didn't stick — check and re-upload it" every
  # time, and re-uploading the same file did the same thing.
  #
  # New uploads are named correctly at ingest (OrganisationAssetsController).
  # This renames the ones already in storage. Renaming is safe: no card can be
  # holding the old path, because the sanitiser is exactly what refused to store
  # it. The blob key is untouched, so nothing is re-uploaded or re-transformed.
  #
  #   bin/rails brand_assets:fix_filenames            # every organisation
  #   bin/rails "brand_assets:fix_filenames[acme]"    # one, by slug or name
  #   DRY_RUN=1 bin/rails brand_assets:fix_filenames  # preview only
  desc "Give brand assets stored under an unusable filename a real image extension: brand_assets:fix_filenames[org]"
  task :fix_filenames, [ :org ] => :environment do |_t, args|
    dry_run = ENV["DRY_RUN"].present?
    ident   = args[:org].to_s.strip
    scope =
      if ident.empty?
        Organisation.all
      else
        org = Organisation.find_by(slug: ident) || Organisation.find_by(name: ident)
        abort "No organisation matching #{ident.inspect} (by slug or name)." unless org
        Organisation.where(id: org.id)
      end

    extensions = { "image/png" => "png", "image/jpeg" => "jpg", "image/gif" => "gif",
                   "image/webp" => "webp", "image/svg+xml" => "svg" }
    renamed = skipped = 0
    scope.find_each do |organisation|
      organisation.assets.attachments.each do |attachment|
        blob = attachment.blob
        name = blob.filename.to_s
        next skipped += 1 if Survey.image_extension?(name)

        ext = extensions[blob.content_type]
        # Not an image type at all: leave it alone and say so — renaming it would
        # only dress a non-image up as one.
        next warn("  ? #{organisation.slug} / #{name} — #{blob.content_type}, not renamed") unless ext

        fixed = "#{name.presence || 'asset'}.#{ext}"
        puts "  #{dry_run ? '[DRY RUN] ' : ''}#{organisation.slug}: #{name} -> #{fixed}"
        blob.update!(filename: fixed) unless dry_run
        renamed += 1
      rescue => e
        warn "  ! #{organisation.slug} / #{blob&.filename} — #{e.class}: #{e.message}"
      end
    end

    puts "#{dry_run ? '[DRY RUN] ' : ''}Renamed #{renamed} asset(s); skipped #{skipped} (already usable)."
  end
end
