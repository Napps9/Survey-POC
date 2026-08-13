class Comms::CampaignsController < Comms::BaseController
  include Comms::BuilderMedia

  # The autosave payload's writable surface. Status, compiled_* and
  # scheduled_snapshot are deliberately absent: state moves through the
  # model's transition methods only (the freeze-at-approval rule).
  UPDATABLE_KEYS = %w[title subject preheader from_name reply_to design audience subject_variants].freeze

  before_action :set_campaign,
                only: %i[edit update destroy preview image moderate_image pexels_search
                         audience_count send_now test_send cancel_send status
                         schedule cancel_schedule]
  before_action :require_editable!, only: %i[update image]

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
                   warnings: @campaign.warnings, subject_review: @campaign.subject_review }
  end

  def destroy
    @campaign.destroy!
    redirect_to comms_path, notice: t("flash.comms.campaign_deleted")
  end

  # Live recipient count for the audience panel. POST because the definition
  # is a JSON body; resolved by the same resolver the send path uses, so the
  # number shown is the number mailed.
  def audience_count
    render json: { ok: true, count: Comms::AudienceResolver.count(audience_definition_param) }
  end

  # Approve and go: freeze (compile + snapshot) and enqueue the dispatcher
  # immediately. The freezer's refusals (no subject, warnings, empty
  # audience) come back as the flash alert.
  def send_now
    result = Comms::CampaignFreezer.call(@campaign)
    if result.ok?
      Comms::StartCampaignSendJob.perform_later(@campaign.id)
      redirect_to edit_comms_campaign_path(@campaign), notice: t("flash.comms.send_started")
    else
      redirect_to edit_comms_campaign_path(@campaign), alert: result.error
    end
  end

  # Proof to the author's own inbox — current document, nothing frozen,
  # nothing tracked.
  def test_send
    Comms::CampaignMailer.test_email(@campaign.id, Current.user.email_address).deliver_now
    redirect_to edit_comms_campaign_path(@campaign),
                notice: t("flash.comms.test_sent", email: Current.user.email_address)
  end

  # Book a future send: same freeze as send-now plus a wall-clock target.
  # The primary trigger is set(wait_until:); the 5-minute sweeper is the
  # safety net for a job lost to a restart.
  def schedule
    at = begin
      Time.iso8601(params[:scheduled_at].to_s)
    rescue ArgumentError
      nil
    end
    unless at&.future?
      return redirect_to edit_comms_campaign_path(@campaign),
                         alert: t("comms.editor.schedule_invalid", default: "Pick a time in the future.")
    end

    result = Comms::CampaignFreezer.call(@campaign, scheduled_for: at)
    if result.ok?
      Comms::StartCampaignSendJob.set(wait_until: at).perform_later(@campaign.id)
      redirect_to edit_comms_campaign_path(@campaign), notice: t("flash.comms.schedule_set")
    else
      redirect_to edit_comms_campaign_path(@campaign), alert: result.error
    end
  end

  # Call the booking off: back to a plain draft. The already-queued job is
  # not deleted — its own guard (must be `scheduled` and due) makes the
  # stale firing a no-op.
  def cancel_schedule
    if @campaign.scheduled?
      Comms::CampaignFreezer.unfreeze!(@campaign)
      redirect_to edit_comms_campaign_path(@campaign), notice: t("flash.comms.schedule_cancelled")
    else
      redirect_to edit_comms_campaign_path(@campaign)
    end
  end

  # Mid-flight stop: queued recipients are skipped, already-sent mail is
  # already sent — the campaign closes as cancelled. The batch job also
  # notices between batches.
  def cancel_send
    if @campaign.sending?
      @campaign.update_columns(status: "cancelled", updated_at: Time.current)
      @campaign.email_campaign_recipients.where(status: "queued")
               .update_all(status: "skipped", updated_at: Time.current)
      redirect_to edit_comms_campaign_path(@campaign), notice: t("flash.comms.send_cancelled")
    else
      redirect_to edit_comms_campaign_path(@campaign)
    end
  end

  # Status JSON for the polling panel (the verto_build shape).
  def status
    counts = @campaign.email_campaign_recipients.group(:status).count
    render json: { ok: true, status: @campaign.status,
                   recipient_count: @campaign.recipient_count,
                   sent_at: @campaign.sent_at, counts: counts }
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

  def builder_record
    @campaign
  end

  def require_editable!
    return unless @campaign.editing_locked?

    render json: { ok: false, error: "This campaign is no longer editable." }, status: :locked
  end

  def playverto_brand
    Organisation.find_by(slug: CommsAccess::PLAYVERTO_SLUG)&.read_attribute(:default_brand_palette)
  end
end
