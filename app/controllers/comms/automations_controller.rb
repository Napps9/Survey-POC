class Comms::AutomationsController < Comms::BaseController
  include Comms::BuilderMedia

  UPDATABLE_KEYS = %w[name subject preheader from_name reply_to design
                      trigger_type delay_minutes params conditions send_hour send_days].freeze

  before_action :set_automation,
                only: %i[edit update destroy preview image moderate_image pexels_search
                         toggle test_send]

  def index
    @automations = EmailAutomation.recent
  end

  def create
    automation = EmailAutomation.create!(
      created_by: Current.user,
      design: Comms::EmailDocument.starter_document(brand: playverto_brand)
    )
    redirect_to edit_comms_automation_path(automation)
  end

  def edit
    @hide_main_nav = true
    @playverto_brand = playverto_brand
    @organisations = Organisation.order(:name)
    @recent_runs = @automation.email_automation_runs.order(created_at: :desc).limit(12)
  end

  # Same autosave shape as campaigns: only keys present in the payload are
  # touched, numbers coerced, unknown trigger types dropped rather than
  # bounced (the select can't produce them; junk shouldn't 500 the save).
  def update
    payload = request.request_parameters
    # The shared editor serializes its title pill as "title"; here that's
    # the automation's name.
    payload["name"] = payload.delete("title") if payload.key?("title")
    UPDATABLE_KEYS.each do |key|
      next unless payload.key?(key)

      value = payload[key]
      case key
      when "name" then next if value.blank?
      when "trigger_type" then next unless EmailAutomation::TRIGGER_TYPES.include?(value)
      when "delay_minutes" then value = value.to_i.clamp(0, 129_600)
      when "send_hour" then value = value.presence && value.to_i.clamp(0, 23)
      when "params", "conditions" then value = value.is_a?(Hash) ? value : {}
      end
      @automation.public_send("#{key}=", value)
    end
    @automation.save!
    # Editing an automation that no longer qualifies disables it rather than
    # sending something half-built.
    @automation.update_columns(enabled: false) if @automation.enabled? && !@automation.enableable?
    render json: { ok: true, id: @automation.id, updated_at: @automation.updated_at,
                   warnings: @automation.warnings, enabled: @automation.enabled? }
  end

  def destroy
    @automation.destroy!
    redirect_to comms_automations_path, notice: t("flash.comms.automation_deleted")
  end

  def toggle
    if @automation.enabled?
      @automation.update!(enabled: false)
      redirect_to edit_comms_automation_path(@automation), notice: t("flash.comms.automation_disabled")
    elsif @automation.enableable?
      @automation.update!(enabled: true)
      redirect_to edit_comms_automation_path(@automation), notice: t("flash.comms.automation_enabled")
    else
      redirect_to edit_comms_automation_path(@automation),
                  alert: (@automation.warnings.first ||
                          t("comms.editor.needs_subject", default: "Give the email a subject first."))
    end
  end

  def test_send
    Comms::AutomationMailer.test_email(@automation.id, Current.user.email_address).deliver_now
    redirect_to edit_comms_automation_path(@automation),
                notice: t("flash.comms.test_sent", email: Current.user.email_address)
  end

  private

  def set_automation
    @automation = EmailAutomation.find(params[:id])
  end

  def builder_record
    @automation
  end

  def playverto_brand
    Organisation.find_by(slug: CommsAccess::PLAYVERTO_SLUG)&.read_attribute(:default_brand_palette)
  end
end
