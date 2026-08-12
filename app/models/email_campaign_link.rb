# A click-trackable destination, written at freeze time from the compiled
# document. The URL is the campaign author's, stored server-side — the click
# endpoint looks rows up by id scoped to the recipient's campaign and never
# accepts a URL from the request.
class EmailCampaignLink < ApplicationRecord
  # Anchored both ends and whitespace-free: this value is redirected to and
  # embedded in mail, so it is a whole URL or it is nothing.
  URL_FORMAT = %r{\Ahttps?://\S+\z}i

  belongs_to :email_campaign

  validates :url, presence: true, format: { with: URL_FORMAT }
end
