# SVG blobs are now served inline (config/initializers/active_storage.rb)
# instead of as attachment downloads, and new uploads pass through
# SvgSanitizer.clean_document first. Anything attached BEFORE that gate
# existed must be scrubbed in place, or a previously-uploaded malicious SVG
# would become same-origin stored XSS the moment the initializer ships.
# Organisation logos and brand-library assets are the only attachments that
# accept SVG.
class SanitizeStoredSvgBrandAssets < ActiveRecord::Migration[8.1]
  def up
    ActiveStorage::Attachment.where(record_type: "Organisation").includes(:blob).find_each do |attachment|
      blob = attachment.blob
      next unless blob&.content_type == "image/svg+xml"

      cleaned = SvgSanitizer.clean_document(blob.download)
      if cleaned.nil?
        # Unsalvageable content must not survive to be served inline. Losing a
        # broken logo beats keeping a stored-XSS candidate.
        attachment.purge
      else
        blob.upload(StringIO.new(cleaned), identify: false)
        blob.save!
      end
    rescue ActiveStorage::FileNotFoundError
      next
    end
  end

  def down
    # Sanitisation cannot be reversed; nothing to do.
  end
end
