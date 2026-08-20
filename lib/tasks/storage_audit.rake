namespace :storage do
  # Which accounts lost uploaded files, and what exactly they lost.
  #
  # Active Storage keeps the *record* of an attachment in Postgres and the file
  # itself on the storage volume, so a wiped volume leaves the database
  # perfectly intact and pointing at files that are no longer there. Nothing in
  # the app notices — a card still references its image, the image just renders
  # blank. This walks every blob and asks the service whether the file is
  # actually present, then groups whatever is missing by organisation, which is
  # the list you need before writing to anyone.
  #
  # Read-only. Run it against production (`render ssh`, or a Render shell):
  #   bin/rails storage:missing_files
  desc "Report organisations with attachments whose underlying files are gone"
  task missing_files: :environment do
    # Attachments hang off several different models; only some lead back to an
    # account. Anything unmapped is reported separately rather than being
    # silently dropped from the count.
    organisation_for = lambda do |attachment|
      case attachment.record_type
      when "Organisation" then Organisation.find_by(id: attachment.record_id)
      when "Survey"       then Survey.find_by(id: attachment.record_id)&.organisation
      when "VertoBuild"   then VertoBuild.find_by(id: attachment.record_id)&.organisation
      end
    end

    label_for = lambda do |name|
      { "logo" => "organisation logo", "assets" => "brand library images", "card_images" => "card images" }
        .fetch(name, name)
    end

    missing = []
    checked = 0

    ActiveStorage::Blob.find_each(batch_size: 200) do |blob|
      checked += 1
      next if blob.service.exist?(blob.key)

      missing.concat(blob.attachments.to_a)
    rescue => e
      warn "  could not check blob #{blob.id} (#{blob.key}): #{e.class}: #{e.message}"
    end

    puts ""
    puts "blobs checked: #{checked}"
    puts "attachments whose file is missing: #{missing.size}"

    if missing.empty?
      puts "Nothing missing — every attachment's file is present."
      next
    end

    grouped = missing.group_by { |attachment| organisation_for.call(attachment) }
    known   = grouped.except(nil).sort_by { |org, _| org.name.to_s.downcase }

    puts "affected organisations: #{known.size}"
    puts ""

    known.each do |org, attachments|
      admins = org.memberships.admin.includes(:user).map { |m| m.user.email_address }.sort

      puts "=" * 72
      puts "#{org.name} (id #{org.id})"
      puts "  admins: #{admins.any? ? admins.join(', ') : '(none)'}"

      attachments.group_by(&:name).sort_by(&:first).each do |name, list|
        puts "  #{label_for.call(name)}: #{list.size}"
        next unless name == "card_images"

        # Card images are worth naming individually — the owner has to find each
        # affected card in the editor to replace it.
        Survey.where(id: list.map(&:record_id).uniq).order(:title).each do |survey|
          puts "    - #{survey.title} (#{list.count { |a| a.record_id == survey.id }})"
        end
      end
      puts ""
    end

    orphans = grouped[nil]
    next if orphans.blank?

    puts "=" * 72
    puts "#{orphans.size} missing attachment(s) not traceable to an organisation:"
    orphans.group_by { |a| [ a.record_type, a.name ] }.each do |(type, name), list|
      puts "  #{type}##{name}: #{list.size}"
    end
  end
end
