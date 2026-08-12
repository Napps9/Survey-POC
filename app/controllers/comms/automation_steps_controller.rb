class Comms::AutomationStepsController < Comms::BaseController
  include Comms::BuilderMedia

  UPDATABLE_KEYS = %w[subject preheader design delay_minutes send_hour send_days].freeze

  before_action :set_automation
  before_action :set_step, only: %i[edit update destroy preview]

  def create
    step = @automation.email_automation_steps.create!(
      position: (@automation.email_automation_steps.maximum(:position) || 0) + 1,
      # A day after the primary by default — counted from the trigger
      # anchor, like every step delay.
      delay_minutes: @automation.delay_minutes + 1440,
      design: Comms::EmailDocument.starter_document(brand: playverto_brand)
    )
    redirect_to edit_comms_automation_step_path(@automation, step)
  end

  def edit
    @hide_main_nav = true
    @playverto_brand = playverto_brand
  end

  def update
    payload = request.request_parameters
    UPDATABLE_KEYS.each do |key|
      next unless payload.key?(key)

      value = payload[key]
      case key
      when "delay_minutes" then value = value.to_i.clamp(0, 129_600)
      when "send_hour" then value = value.presence && value.to_i.clamp(0, 23)
      end
      @step.public_send("#{key}=", value)
    end
    @step.save!
    render json: { ok: true, id: @step.id, updated_at: @step.updated_at, warnings: @step.warnings }
  end

  def destroy
    @step.destroy!
    redirect_to edit_comms_automation_path(@automation), notice: t("flash.comms.step_deleted")
  end

  private

  def set_automation
    @automation = EmailAutomation.find(params[:automation_id])
  end

  def set_step
    @step = @automation.email_automation_steps.find(params[:id])
  end

  def builder_record
    @step
  end

  def playverto_brand
    Organisation.find_by(slug: CommsAccess::PLAYVERTO_SLUG)&.read_attribute(:default_brand_palette)
  end
end
