# A shareable "review my wording" link. See the migration for why review links
# are a table rather than one more token on `surveys`.
#
# Access posture, stated once here because three places depend on it:
# holding the token is the whole of the authorisation. That is the feature —
# the people who can tell you whether your Spanish reads well generally do not
# have a Playverto account — so everything that follows a capability URL
# follows this one: noindex on the response (ApplicationController::
# NOINDEX_PATHS), Disallow in robots.txt, a pause that keeps the URL alive
# (active: false) and a revoke that destroys it.
class LanguageCheckLink < ApplicationRecord
  belongs_to :survey
  belongs_to :created_by_user, class_name: "User", optional: true
  has_many :language_checks, dependent: :nullify
  has_many :language_check_notes, dependent: :nullify

  MAX_NAME = 60

  before_validation :generate_token, on: :create
  validates :token, presence: true, uniqueness: true

  scope :active, -> { where(active: true) }

  # The languages this link may see and act on. Stored empty for "all of
  # them", and always intersected with the Verto's CURRENT languages: a link
  # minted for French stops offering French the moment the creator drops
  # French from the Verto, rather than showing a language the deck no longer
  # has.
  def visible_locales
    scoped = SupportedLocales.sanitize_list(locales, fallback: [])
    return survey.verto_locales if scoped.empty?
    survey.verto_locales & scoped
  end

  def sees_locale?(locale)
    visible_locales.include?(locale.to_s)
  end

  # Whether this link may change the wording, as opposed to only approving and
  # commenting on it. Revoking edit rights on a live link takes effect on the
  # next request — the check is here and in the controller, never in the view
  # alone.
  def editable?
    active? && can_edit?
  end

  def display_name
    name.presence || I18n.t("language_check.link_default_name")
  end

  # Cheap "is anyone actually using this link" signal for the owner's panel.
  # Written at most once a minute so an ordinary review session — dozens of
  # approvals in a row — does not turn into dozens of writes.
  def touch_seen!
    return if last_seen_at.present? && last_seen_at > 1.minute.ago
    update_column(:last_seen_at, Time.current)
  end

  private

  def generate_token
    self.token ||= SecureRandom.urlsafe_base64(18)
  end
end
