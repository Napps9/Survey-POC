# Lays this week's copy out as an email document, in the same block grammar
# the builder edits — so the owner opens a generated draft and edits it with
# exactly the controls they'd have on a hand-built one.
#
# The design is the Playverto palette applied to an email's constraints: a
# navy masthead carrying the logo, each piece of news as an accent-barred
# feature card, the Projects section as a tinted callout, and one mint CTA.
# Colour comes from the org's brand palette where it exists, so a rebrand
# moves the newsletter with it.
#
# Everything here must clear Comms::EmailDocument.warnings, which is the send
# gate: a button whose href is blank OR the literal "https://" blocks the
# freeze. The CTA therefore points at a real absolute URL. The masthead logo
# is exempt — a blank src falls back to the wordmark as live text.
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

    PAPER      = "#FFFFFF".freeze
    CANVAS     = "#EEF1F8".freeze
    INK        = "#1C2034".freeze
    CARD_TINT  = "#F6F8FC".freeze
    LOGO_PATH  = "playverto-email.png".freeze

    def build(copy, brand: nil, cta_url: nil, week: nil)
      palette = BrandPalette.resolve(brand || {})
      url     = cta_url.presence || default_cta_url
      accent  = palette["primary"]
      blocks  = []

      blocks << masthead(palette, week: week, url: url)
      blocks << heading(copy["subject"], level: 2, color: INK)
      blocks << text(copy["intro"], color: INK)

      items = Array(copy["items"])
      if items.any?
        blocks << heading("New this week", level: 3, color: accent_ink(accent))
        items.each { |item| blocks << feature(item, accent: accent) }
      end

      blocks << callout(PROJECTS_HEADING, PROJECTS_PLACEHOLDER, accent: palette["cta"])
      blocks << spacer(8)
      blocks << button(copy["cta_label"], url, palette: palette)
      blocks << text(copy["sign_off"], color: INK, align: "center") if copy["sign_off"].to_s.strip.present?

      { "version" => 1, "settings" => settings(palette), "blocks" => blocks }
    end

    # A newsletter's own paper: the app's canvas grey behind white paper, with
    # links in the brand colour. Hand-built campaigns keep EmailDocument's
    # neutral defaults — this is the newsletter's identity, not a global one.
    def settings(palette)
      Comms::EmailDocument.default_settings.merge(
        "backgroundColor"        => CANVAS,
        "contentBackgroundColor" => PAPER,
        "textColor"              => INK,
        "linkColor"              => palette["primary"],
        "contentWidth"           => 600
      )
    end

    # The freeze absolutizes root-relative paths against Comms.app_origin, but
    # that is blank when no host is configured (dev). Falling back to the
    # public site keeps the button valid in every environment — a blank href
    # is a blocked send.
    def default_cta_url
      Comms.app_origin.presence || "https://playverto.com"
    end

    def masthead(palette, week:, url:)
      Comms::EmailDocument.create_block("masthead").merge(
        "src"             => logo_url,
        "alt"             => "Playverto",
        "href"            => url,
        "eyebrow"         => week ? "Week of #{week.strftime("%-d %B %Y")}" : "",
        "backgroundColor" => palette["bg"],
        "textColor"       => BrandPalette.contrast_text(palette["bg"]),
        "align"           => "center"
      )
    end

    # SVG doesn't render in most inboxes, so the masthead uses the raster
    # export. Root-relative here; the freeze makes it absolute.
    def logo_url
      ActionController::Base.helpers.image_path(LOGO_PATH)
    rescue StandardError
      ""
    end

    def feature(item, accent:)
      Comms::EmailDocument.create_block("feature").merge(
        "eyebrow"         => "",
        "text"            => item["title"].to_s,
        "body"            => item["body"].to_s,
        "href"            => "",
        "linkLabel"       => "",
        "accentColor"     => accent,
        "backgroundColor" => CARD_TINT,
        "textColor"       => INK
      )
    end

    def callout(label, body, accent:)
      Comms::EmailDocument.create_block("callout").merge(
        "eyebrow"         => label,
        "text"            => body,
        "accentColor"     => accent,
        "backgroundColor" => CARD_TINT,
        "textColor"       => INK
      )
    end

    # A heading tinted with the brand only reads if it stays legible on white;
    # the mint is a background colour, not a text colour.
    def accent_ink(accent)
      BrandPalette.luminance(accent) > 0.55 ? INK : accent
    end

    def heading(value, level:, color:, align: "left")
      Comms::EmailDocument.create_block("heading")
                          .merge("text" => value.to_s, "level" => level,
                                 "align" => align, "color" => color)
    end

    def text(value, color:, align: "left")
      Comms::EmailDocument.create_block("text")
                          .merge("text" => value.to_s, "align" => align, "color" => color)
    end

    def spacer(height)
      Comms::EmailDocument.create_block("spacer").merge("height" => height)
    end

    def button(label, url, palette:)
      Comms::EmailDocument.create_block("button").merge(
        "text"            => label.presence || "Open VertoNow",
        "href"            => url,
        "align"           => "center",
        "backgroundColor" => palette["cta"],
        "textColor"       => BrandPalette.contrast_text(palette["cta"]),
        "radius"          => 100
      )
    end
  end
end
