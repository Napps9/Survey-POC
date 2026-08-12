# The builder endpoints campaigns and automations share: the compiled
# preview and the media-picker trio (persist upload / moderate / Pexels).
# The including controller defines builder_record (a model with #document,
# #preheader and images attachments).
module Comms::BuilderMedia
  extend ActiveSupport::Concern

  included do
    # The compiled email is wall-to-wall inline styles; the app CSP would
    # strip them inside the preview iframe.
    content_security_policy false, only: :preview
  end

  # The compiled artifact, framed by the builder's sandboxed iframe — the
  # preview shows what the compiler produces, not what the canvas shows.
  def preview
    html = Comms::EmailRenderer.render_html(
      builder_record.document, preheader: builder_record.preheader, unsubscribe_url: "#"
    )
    render html: html.html_safe, layout: false
  end

  # Media-picker persistence (mirrors surveys#card_image): store the
  # moderated upload once as a blob, carry a short path on the block instead
  # of megabytes of base64 in the design json.
  def image
    decoded = Survey::CardImageStore.decode(params[:image].to_s)
    unless decoded
      return render json: { ok: false, error: "That image couldn't be stored." },
                    status: :unprocessable_entity
    end

    bytes, content_type = decoded
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(bytes),
      filename: "comms-#{SecureRandom.hex(8)}.#{Survey::CardImageStore::EXTENSIONS.fetch(content_type)}",
      content_type: content_type
    )
    builder_record.images.attach(blob)
    render json: { ok: true, url: rails_blob_path(blob, only_path: true) }
  rescue => e
    ErrorReporting.report("#{self.class.name}#image", e)
    render json: { ok: false, error: "That image couldn't be stored." }, status: :unprocessable_entity
  end

  # Mirrors surveys#moderate_image, minus the audience-age dimension —
  # recipients are adults (platform users and imported contacts).
  def moderate_image
    image = params[:image].to_s

    return render json: { ok: true } unless ImageModerator.configured?
    if image.blank? || !image.start_with?("data:image/")
      return render json: { ok: false, reason: "That doesn't look like an image." }
    end

    verdict = ImageModerator.new.call(data_url: image, audience_age: nil)
    if verdict[:safe]
      render json: { ok: true }
    elsif verdict[:ambiguous]
      render json: { ok: false, reason: could_not_verify_image_message }, status: :bad_gateway
    else
      render json: { ok: false, reason: verdict[:reason].presence || "That image isn't appropriate for an email." }
    end
  rescue => e
    ErrorReporting.report("#{self.class.name}#moderate_image", e)
    render json: { ok: false, reason: could_not_verify_image_message }, status: :bad_gateway
  end

  # Pexels search for image blocks (mirrors surveys#pexels_search, photos
  # only, landscape, adult audience).
  def pexels_search
    raw = params[:q].to_s.strip
    return render json: { images: [] } if raw.blank?
    return render json: { images: [], error: "search_unavailable" } unless PexelsClient.configured?

    query = ContentSafety.scrub_query(raw, [])
    return render json: { images: [], error: "search_blocked" } if query.blank?

    images = PexelsClient.new.search(query: query, orientation: "landscape", per_page: 24)
      .select { |p| ContentSafety.safe?(p["alt"], []) }
      .map do |p|
        {
          id:               p["id"],
          type:             "photo",
          url:              PexelsClient.url_for(p, :background),
          thumb:            (p["src"] || {})["tiny"],
          photographer:     p["photographer"],
          photographer_url: p["photographer_url"],
          alt:              p["alt"]
        }
      end
    render json: { images: images }
  rescue => e
    ErrorReporting.report("#{self.class.name}#pexels_search", e)
    render json: { images: [], error: "search_failed" }, status: :bad_gateway
  end

  private

  def could_not_verify_image_message
    "The image couldn't be checked just now — try again in a moment."
  end
end
