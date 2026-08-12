# Freeze-time link pass: every absolute http(s) href in the compiled HTML is
# replaced with a {{link:<id>}} token backed by an email_campaign_links row.
# At send time the personalizer swaps tokens for short per-recipient redirect
# URLs — so destinations are author-stored and looked up by id, never carried
# in the tracking URL (no open redirect, and no 2KB hrefs in the mail).
#
# HTML entities are decoded before storing (the compiled HTML escapes & as
# &amp; inside attributes — storing the escaped form would 404 real URLs, the
# classic &amp;amp; bug Temple's personalize tests pin). mailto: links and the
# {{unsubscribe_url}} placeholder pass through untouched. Idempotent: an
# already-tokenized href no longer matches https?.
module Comms
  module LinkExtractor
    module_function

    def extract!(campaign, html)
      seen = {}
      html.gsub(/href="([^"]*)"/) do |match|
        raw = CGI.unescapeHTML(Regexp.last_match(1))
        # Only whole, whitespace-free URLs are trackable (the model's own
        # rule); anything else stays inline, untracked, rather than failing
        # the freeze.
        if raw.match?(EmailCampaignLink::URL_FORMAT)
          id = seen[raw] ||= campaign.email_campaign_links.create!(url: raw).id
          %(href="{{link:#{id}}}")
        else
          match
        end
      end
    end
  end
end
