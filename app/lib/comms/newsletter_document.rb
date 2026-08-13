# Lays this week's copy out as an email document, in the same block grammar
# the builder edits — so the owner opens a generated draft and edits it with
# exactly the controls they'd have on a hand-built one.
#
# Everything here must clear Comms::EmailDocument.warnings, which is the send
# gate: a button whose href is blank OR the literal "https://" blocks the
# freeze. The CTA therefore points at a real absolute URL, and no image blocks
# are emitted at all (an empty src would block it too).
module Comms
  module NewsletterDocument
    module_function

    PROJECTS_HEADING = "Projects".freeze

    # Deliberately reads as an instruction rather than as copy: it is the one
    # block the owner must replace before Monday, and it should be impossible
    # to mistake for finished text if it survives to a proof read.
    PROJECTS_PLACEHOLDER =
      "[Add this week's project news here — what's in flight, what's " \
      "landing next, anything you want early adopters to weigh in on. " \
      "Delete this block if there's nothing to share this week.]".freeze

    def build(copy, brand: nil, cta_url: nil)
      url = cta_url.presence || default_cta_url
      blocks = []

      blocks << heading(copy["subject"], brand: brand, level: 2, align: "left")
      blocks << text(copy["intro"], brand: brand)
      blocks << divider(brand: brand)

      if Array(copy["items"]).any?
        blocks << heading("New this week", brand: brand, level: 3, align: "left")
        Array(copy["items"]).each do |item|
          blocks << heading(item["title"], brand: brand, level: 3, align: "left")
          blocks << text(item["body"], brand: brand) if item["body"].to_s.strip.present?
        end
        blocks << divider(brand: brand)
      end

      blocks << heading(PROJECTS_HEADING, brand: brand, level: 3, align: "left")
      blocks << text(PROJECTS_PLACEHOLDER, brand: brand)
      blocks << divider(brand: brand)

      blocks << button(copy["cta_label"], url, brand: brand)
      blocks << text(copy["sign_off"], brand: brand) if copy["sign_off"].to_s.strip.present?

      {
        "version"  => 1,
        "settings" => Comms::EmailDocument.default_settings(brand),
        "blocks"   => blocks
      }
    end

    # The freeze absolutizes root-relative paths against Comms.app_origin, but
    # that is blank when no host is configured (dev). Falling back to the
    # public site keeps the button valid in every environment — a blank href
    # is a blocked send.
    def default_cta_url
      Comms.app_origin.presence || "https://playverto.com"
    end

    def heading(value, brand:, level:, align:)
      Comms::EmailDocument.create_block("heading", brand: brand)
                          .merge("text" => value.to_s, "level" => level, "align" => align)
    end

    def text(value, brand:)
      Comms::EmailDocument.create_block("text", brand: brand).merge("text" => value.to_s)
    end

    def divider(brand:)
      Comms::EmailDocument.create_block("divider", brand: brand)
    end

    def button(label, url, brand:)
      Comms::EmailDocument.create_block("button", brand: brand)
                          .merge("text" => label.presence || "Open VertoNow",
                                 "href" => url, "align" => "center")
    end
  end
end
