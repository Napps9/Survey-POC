# Classifies a User-Agent into a coarse device bucket for response analytics.
#
# Deliberately lossy. The researcher-facing question is "did people answer this
# on a phone or at a desk?", which three buckets answer; the raw UA string would
# answer far more than that and is a fingerprinting vector we don't want sitting
# next to respondents' answers. Nothing here is persisted except the bucket.
#
# The matching is intentionally simple substring sniffing rather than a full UA
# database: device detection is a losing arms race, this only needs to be right
# in aggregate, and an unrecognised UA lands in "unknown" instead of being
# silently miscounted as desktop.
module DeviceKind
  PHONE   = "phone".freeze
  TABLET  = "tablet".freeze
  DESKTOP = "desktop".freeze
  UNKNOWN = "unknown".freeze

  # Order matters: an iPad's UA contains "Mobile", and an Android tablet's
  # contains "Android" without "Mobile", so tablets must be tested first.
  TABLET_HINTS = [ "ipad", "tablet", "kindle", "silk", "playbook" ].freeze
  PHONE_HINTS  = [ "iphone", "ipod", "windows phone", "blackberry", "bb10", "opera mini", "iemobile" ].freeze

  def self.from(user_agent)
    ua = user_agent.to_s.downcase
    return UNKNOWN if ua.blank?

    return TABLET if TABLET_HINTS.any? { |hint| ua.include?(hint) }
    # Android without "mobile" is Google's own signal for a tablet.
    return TABLET if ua.include?("android") && !ua.include?("mobile")
    return PHONE  if PHONE_HINTS.any? { |hint| ua.include?(hint) }
    return PHONE  if ua.include?("android") || ua.include?("mobile")

    DESKTOP
  end
end
