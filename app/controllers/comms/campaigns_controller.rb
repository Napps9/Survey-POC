class Comms::CampaignsController < Comms::BaseController
  # The autosave payload's writable surface. Status, compiled_* and
  # scheduled_snapshot are deliberately absent: state moves through the
  # model's transition methods only (the freeze-at-approval rule).
  UPDATABLE_KEYS = %w[title subject preheader from_name reply_to design audience subject_variants].freeze

  before_action :set_campaign, only: %i[edit update destroy preview image moderate_image pexels_search]
  before_action :require_editable!, only: %i[update image]

  # The compiled email is wall-to-wall inline styles; the app CSP would
  # strip them inside the preview iframe.
  content_security_policy false, only: :preview

  def index
    @campaigns = EmailCampaign.recent
  end

  def create
    campaign = EmailCampaign.create!(
      created_by: Current.user,
      design: Comms::EmailDocument.starter_document(brand: playverto_brand)
    )
    redirect_to edit_comms_campaign_path(campaign)
  end

  def edit
    @hide_main_nav = true
    @playverto_brand = playverto_brand
    @organisations = Organisation.order(:name)
    @lists = EmailList.recent
  end

  # JSON autosave from the builder. Only keys present in the payload are
  # touched (surveys#update's rule), so a small PATCH shares this endpoint
  # without wiping the rest of the campaign.
  def update
    payload = request.request_parameters
    UPDATABLE_KEYS.each do |key|
      next unless payload.key?(key)

      value = payload[key]
      # A blank title is dropped, not saved — same guard as the Verto title.
      next if key == "title" && value.blank?

      @campaign.public_send("#{key}=", value)
    end
    @campaign.save!
    render json: { ok: true, id: @campaign.id, updated_at: @campaign.updated_at,
                   warnings: @campaign.warnings }
  end

  def destroy
    @campaign.destroy!
    redirect_to comms_path, notice: t("flash.comms.campaign_deleted")
  end

  # The compiled artifact, framed by the builder's sandboxed iframe — the
  # preview shows what the compiler produces, not what the canvas shows.
  def preview
    html = Comms::EmailRenderer.render_html(
      @campaign.document, preheader: @campaign.preheader, unsubscribe_url: "#"
    )
    render html: html.html_safe, layout: false
  end

  # Media-picker persistence endpoint (mirrors surveys#card_image): store the
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
    @campaign.images.attach(blob)
    render json: { ok: true, url: rails_blob_path(blob, only_path: true) }
  rescue => e
    ErrorReporting.report("Comms::CampaignsController#image", e)
    render json: { ok: false, error: "That image couldn't be stored." }, status: :unprocessable_entity
  end

  # Mirrors surveys#moderate_image, minus the audience-age dimension —
  # campaign recipients are adults (platform users and imported contacts).
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
    ErrorReporting.report("Comms::CampaignsController#moderate_image", e)
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
    ErrorReporting.report("Comms::CampaignsController#pexels_search", e)
    render json: { images: [], error: "search_failed" }, status: :bad_gateway
  end

  # Live recipient count for the audience panel. POST because the definition
  # is a JSON body; resolved by the same resolver the send path uses, so the
  # number shown is the number mailed.
  def audience_count
    render json: { ok: true, count: Comms::AudienceResolver.count(audience_definition_param) }
  end

  private

  # The posted definition reduced to typed scalars before it goes anywhere
  # near a query: ids through Integer(), strings through to_s, unknown keys
  # dropped. The resolver only ever builds parameterized AR relations, but
  # this keeps the taint analysis (and the reader) from having to prove that.
  def audience_definition_param
    raw = request.request_parameters["audience"]
    return {} unless raw.is_a?(Hash)

    out = { "kind" => raw["kind"].to_s }
    out["role"] = raw["role"].to_s if raw.key?("role")
    if raw.key?("organisation_ids")
      out["organisation_ids"] = Array(raw["organisation_ids"]).filter_map { |v| Integer(v, exception: false) }
    end
    if raw.key?("user_ids")
      out["user_ids"] = Array(raw["user_ids"]).filter_map { |v| Integer(v, exception: false) }
    end
    out["emails"] = Array(raw["emails"]).map { |e| Comms.normalize_email(e) } if raw.key?("emails")
    out["list_id"] = Integer(raw["list_id"], exception: false) if raw.key?("list_id")
    out
  end

  def set_campaign
    @campaign = EmailCampaign.find(params[:id])
  end

  def require_editable!
    return unless @campaign.editing_locked?

    render json: { ok: false, error: "This campaign is no longer editable." }, status: :locked
  end

  def playverto_brand
    Organisation.find_by(slug: CommsAccess::PLAYVERTO_SLUG)&.read_attribute(:default_brand_palette)
  end

  def could_not_verify_image_message
    "The image couldn't be checked just now — try again in a moment."
  end
end
