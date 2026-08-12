class Comms::ListsController < Comms::BaseController
  IMPORT_CAP = 10_000

  before_action :set_list, only: %i[show destroy]

  def index
    @lists = EmailList.recent
  end

  def show
    @contacts = @list.email_list_contacts.order(:email).limit(100)
  end

  # One action imports either a pasted block (one "email" or "email, name"
  # per line) or an uploaded CSV (email in the first column, optional name in
  # the second; a header row is skipped when it doesn't parse as an address).
  # Malformed rows are skipped and counted, never fatal — a 9,000-row list
  # with three typos should import 8,997 contacts, not error out.
  def create
    name = params[:name].to_s.strip
    if name.blank?
      redirect_to comms_lists_path, alert: t("comms.lists.name_missing", default: "Give the list a name.")
      return
    end

    rows = parse_rows
    if rows.empty?
      redirect_to comms_lists_path, alert: t("comms.lists.nothing_to_import", default: "No addresses found to import.")
      return
    end

    valid, skipped = validate_rows(rows)
    list = EmailList.create!(name: name, created_by: Current.user)
    if valid.any?
      now = Time.current
      EmailListContact.insert_all(
        valid.map { |r| { email_list_id: list.id, email: r[:email], name: r[:name], created_at: now, updated_at: now } },
        unique_by: [ :email_list_id, :email ]
      )
    end
    list.recount!

    redirect_to comms_list_path(list),
                notice: t("flash.comms.list_imported", name: list.name,
                          count: list.contacts_count, skipped: skipped)
  end

  def destroy
    @list.destroy!
    redirect_to comms_lists_path, notice: t("flash.comms.list_deleted")
  end

  private

  def set_list
    @list = EmailList.find(params[:id])
  end

  def parse_rows
    rows = []
    if params[:csv].respond_to?(:read)
      require "csv"
      CSV.parse(params[:csv].read.force_encoding("UTF-8").scrub, liberal_parsing: true) do |cols|
        rows << { email: cols[0].to_s, name: cols[1].to_s.strip.presence }
        break if rows.size > IMPORT_CAP
      end
    end
    params[:emails_text].to_s.each_line do |line|
      email, name = line.split(",", 2).map(&:strip)
      next if email.blank?

      rows << { email: email, name: name.presence }
      break if rows.size > IMPORT_CAP
    end
    rows.first(IMPORT_CAP)
  end

  def validate_rows(rows)
    valid = []
    seen = {}
    skipped = 0
    rows.each do |row|
      email = Comms.normalize_email(row[:email])
      if email.match?(URI::MailTo::EMAIL_REGEXP) && !seen.key?(email)
        seen[email] = true
        valid << { email: email, name: row[:name] }
      else
        skipped += 1
      end
    end
    [ valid, skipped ]
  end
end
