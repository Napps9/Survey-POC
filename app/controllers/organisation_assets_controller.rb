# The account's own brand-asset library. Admins upload images here (from the
# branding page) and they become pickable in every Verto's media picker,
# scoped to this organisation only — the per-account counterpart of the shared
# Verto Library. Attachments live on Organisation#assets (Active Storage).
class OrganisationAssetsController < ApplicationController
  layout "fullscreen"
  before_action :require_admin!

  # POST /organisations/:organisation_id/assets
  # Two shapes: the branding page posts multipart files; the editor's media
  # picker posts JSON with a base64 data URL (`image`), the same payload shape
  # as surveys#card_image, so an upload can also land in the brand library.
  def create
    return create_from_data_url if params[:image].present?

    org   = current_organisation
    files = Array(params[:assets]).reject(&:blank?)

    if files.empty?
      return redirect_to organisation_memberships_path(org), alert: t("flash.organisation_assets.no_files_chosen")
    end
    if org.assets.attachments.size + files.size > Organisation::MAX_ASSETS
      return redirect_to organisation_memberships_path(org),
        alert: t("flash.organisation_assets.asset_limit_exceeded", limit: Organisation::MAX_ASSETS)
    end
    # Validate BEFORE attaching: attaching to a saved record persists
    # immediately, so a bad file would otherwise land in storage before the
    # model validation could reject it.
    if (bad = files.find { |f| !valid_asset?(f) })
      return redirect_to organisation_memberships_path(org),
        alert: t("flash.organisation_assets.invalid_asset_file", filename: bad.original_filename, size: Organisation::ASSET_MAX_BYTES / 1.megabyte)
    end

    # SVG is stored and later served inline (config/initializers/
    # active_storage.rb), so scrub it before it reaches storage. A file the
    # sanitizer can't salvage is rejected like any other invalid asset.
    attachables = files.map do |f|
      name = storable_filename(f.original_filename, f.content_type)
      next { io: f.tempfile.tap(&:rewind), filename: name, content_type: f.content_type } unless f.content_type == "image/svg+xml"
      cleaned = SvgSanitizer.clean_document(f.read)
      if cleaned.nil?
        return redirect_to organisation_memberships_path(org),
          alert: t("flash.organisation_assets.invalid_asset_file", filename: f.original_filename, size: Organisation::ASSET_MAX_BYTES / 1.megabyte)
      end
      { io: StringIO.new(cleaned), filename: name, content_type: "image/svg+xml" }
    end

    org.assets.attach(attachables)
    redirect_to organisation_memberships_path(org),
      notice: t("flash.organisation_assets.assets_added", count: files.size)
  rescue => e
    ErrorReporting.report("OrganisationAssetsController#create", e)
    redirect_to organisation_memberships_path(org), alert: t("flash.organisation_assets.add_failed")
  end

  # DELETE /organisations/:organisation_id/assets/:id
  #
  # Two shapes, like create: the branding page deletes and reloads; the
  # editor's media picker deletes from inside a modal and asks for JSON. A
  # redirect would be the wrong answer there — Turbo would navigate the editor
  # away mid-edit and take the creator's unsaved cards with it.
  def destroy
    org = current_organisation
    # Synchronous purge, like the logo remove — the blob is a small image and
    # the admin expects it gone when the page reloads. `org.assets.attachments`
    # is the whole authorisation story: another account's attachment id simply
    # isn't in this scope and raises RecordNotFound below.
    org.assets.attachments.find(params[:id]).purge

    return render json: { ok: true, id: params[:id].to_i } if request.format.json?

    redirect_to organisation_memberships_path(org), notice: t("flash.organisation_assets.asset_removed")
  rescue ActiveRecord::RecordNotFound
    if request.format.json?
      return render json: { ok: false, error: t("flash.organisation_assets.asset_missing") },
                    status: :not_found
    end
    redirect_to organisation_memberships_path(org), alert: t("flash.organisation_assets.asset_missing")
  end

  private

  DATA_URL   = %r{\Adata:(image/[a-zA-Z0-9.+-]+);base64,(.+)\z}m
  EXTENSIONS = {
    "image/png" => "png", "image/jpeg" => "jpg", "image/gif" => "gif",
    "image/webp" => "webp", "image/svg+xml" => "svg"
  }.freeze

  def create_from_data_url
    org = current_organisation
    if org.assets.attachments.size >= Organisation::MAX_ASSETS
      return render json: { ok: false,
                            error: t("flash.organisation_assets.asset_limit_exceeded", limit: Organisation::MAX_ASSETS) },
                    status: :unprocessable_entity
    end

    decoded = decode_asset_data_url(params[:image].to_s)
    unless decoded
      return render json: { ok: false, error: t("flash.organisation_assets.add_failed") },
                    status: :unprocessable_entity
    end

    bytes, content_type = decoded
    blob = ActiveStorage::Blob.create_and_upload!(
      io:           StringIO.new(bytes),
      filename:     "brand-#{SecureRandom.hex(8)}.#{EXTENSIONS.fetch(content_type)}",
      content_type: content_type
    )
    org.assets.attach(blob)
    attachment = org.assets.attachments.order(:id).last
    # delete_url travels with the tile so the picker never has to build a path
    # from a string. A tile that has just been uploaded is as deletable as one
    # the server rendered — otherwise the only way to undo a mis-upload made in
    # the editor is to leave the editor.
    render json: { ok: true, id: attachment.id,
                   url:        rails_blob_path(blob, only_path: true),
                   thumb:      helpers.as_thumb_path(attachment),
                   delete_url: organisation_asset_path(org, attachment.id, format: :json) }
  rescue => e
    ErrorReporting.report("OrganisationAssetsController#create_from_data_url", e)
    render json: { ok: false, error: t("flash.organisation_assets.add_failed") }, status: :unprocessable_entity
  end

  # [bytes, content_type] for a valid, in-budget brand-asset data URL; nil
  # otherwise. SVG passes through the same sanitiser gate as every other SVG
  # ingress (it is served inline — see config/initializers/active_storage.rb).
  def decode_asset_data_url(value)
    match = DATA_URL.match(value.strip)
    return nil unless match

    content_type = match[1].downcase
    return nil unless Organisation::ASSET_CONTENT_TYPES.include?(content_type)

    bytes = begin
      Base64.strict_decode64(match[2].gsub(/\s+/, ""))
    rescue ArgumentError
      return nil
    end
    return nil if bytes.empty? || bytes.bytesize > Organisation::ASSET_MAX_BYTES

    if content_type == "image/svg+xml"
      bytes = SvgSanitizer.clean_document(bytes)
      return nil unless bytes
    end
    [ bytes, content_type ]
  end

  # The name to store a branding-page upload under. What makes a file a valid
  # asset here is its CONTENT TYPE, but what decides whether the resulting blob
  # path survives Survey.sanitize_image_url is its EXTENSION — so a library
  # image called "logo" or "holiday.jfif" was stored happily, picked happily in
  # the editor, and then silently dropped from the card on save, leaving the
  # creator with "Saved, but an image didn't stick — check and re-upload it."
  # every time, and re-uploading the same file reproduced it exactly.
  #
  # An extension the sanitiser already accepts is kept as-is (the creator's own
  # filename is what the library lists). Anything else gains the one matching
  # its content type — appended rather than substituted, so "report.v2" stays
  # recognisable instead of being truncated to "report".
  def storable_filename(original, content_type)
    base = File.basename(original.to_s).presence || "asset"
    return base if Survey.image_extension?(base)
    "#{base}.#{EXTENSIONS.fetch(content_type)}"
  end

  def valid_asset?(file)
    file.respond_to?(:content_type) &&
      Organisation::ASSET_CONTENT_TYPES.include?(file.content_type) &&
      file.size <= Organisation::ASSET_MAX_BYTES
  end
end
