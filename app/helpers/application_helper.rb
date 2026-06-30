module ApplicationHelper
  # Whether the "Connect to Google Sheets" results export is available (OAuth
  # client configured). Used to hide the button when it can't work.
  def google_sheets_configured?
    GoogleOauthService.configured?
  end

  # Rating answer-type icon, themed to the Verto. The classic star is the
  # default; a Verto whose subject matches one of these keyword groups rates in
  # an icon that fits it — a "space" Verto in rockets, a "food" Verto in
  # burgers, and so on.
  #
  # Matching (see #rating_icon): the signal is the theme PLUS the title and
  # key_insight, tokenised to whole words and singularised so plurals/variants
  # (rockets, fans, dogs…) hit without being hand-listed. The group with the
  # most keyword hits wins (ties break on the order below), so a mixed brief
  # resolves to its dominant subject rather than whichever keyword is listed
  # first. Keywords here are written singular; both sides are singularised so
  # the lists stay short.
  #
  # The ★/☆ star is a monochrome glyph coloured by CSS (grey → gold). Emoji
  # ignore CSS `color`, so they instead render full-colour when active and
  # dim/greyscale when not — hence the `kind` the views/JS switch on.
  RATING_ICON_THEMES = [
    [ %w[space rocket astronaut galaxy cosmos cosmic planet orbit moon mars spacecraft], "🚀" ],
    [ %w[football soccer fifa], "⚽" ],
    [ %w[basketball nba hoop], "🏀" ],
    [ %w[sport fitness gym workout athlete training exercise running marathon], "💪" ],
    [ %w[food eat eating meal restaurant cuisine snack dinner lunch breakfast cooking recipe nutrition], "🍔" ],
    [ %w[coffee cafe barista espresso], "☕" ],
    [ %w[nature climate environment environmental eco sustainability sustainable green earth recycling carbon], "🌍" ],
    [ %w[plant garden gardening flower bloom growth tree forest], "🌱" ],
    [ %w[health wellness wellbeing medical mental healthcare], "❤️" ],
    [ %w[love dating relationship romance valentine wedding marriage], "❤️" ],
    [ %w[music song concert band audio festival playlist gig album], "🎵" ],
    [ %w[money finance financial budget invest investing bank banking salary saving economy economic spending], "💰" ],
    [ %w[travel holiday vacation trip flight tourism adventure destination hotel], "✈️" ],
    [ %w[game gaming gamer esport arcade console], "🎮" ],
    [ %w[movie film cinema tv television streaming show series], "🎬" ],
    [ %w[book reading library education school learning study student teaching academic college university], "📚" ],
    [ %w[pet dog cat animal wildlife veterinary], "🐾" ],
    [ %w[car auto vehicle driving motor automotive], "🚗" ],
    [ %w[tech technology software app digital computer coding data], "💻" ],
    [ %w[fashion style clothing beauty makeup outfit apparel], "👗" ],
    [ %w[water ocean sea beach surf marine river lake], "🌊" ],
    [ %w[party celebration festive birthday], "🎉" ],
    [ %w[work career job business office professional workplace employee], "💼" ],
    [ %w[home house property housing rent mortgage interior], "🏠" ],
    [ %w[news politics political election vote government policy], "📰" ],
    [ %w[science research scientific experiment lab physics chemistry biology], "🔬" ],
    [ %w[art design creative drawing painting illustration], "🎨" ],
    [ %w[photography photo camera photographer], "📷" ],
    [ %w[social media instagram tiktok influencer content], "📱" ]
  ].map { |keywords, glyph| [ keywords.map { |w| w.singularize }.to_set, glyph ] }.freeze

  STAR_RATING_ICON = { on: "★", off: "☆", kind: "star" }.freeze

  # The NPS "liquid container" silhouette, themed per Verto so the scale leans
  # into brand alignment (a glass, a test-tube/thermometer, a popsicle, or the
  # plain pill). Deterministic from the theme (stable across processes via a
  # digest, not String#hash) so a given Verto always gets the same container.
  # Maps to a CSS class `nps-shape-<name>`.
  NPS_CONTAINER_SHAPES = %w[pill glass tube popsicle].freeze

  def nps_container_shape(survey)
    theme = survey&.theme.to_s.strip.downcase
    return NPS_CONTAINER_SHAPES.first if theme.empty?

    idx = Integer(Digest::SHA256.hexdigest(theme)[0, 8], 16) % NPS_CONTAINER_SHAPES.size
    NPS_CONTAINER_SHAPES[idx]
  end

  def rating_icon(survey)
    signal = %i[theme title key_insight]
             .filter_map { |m| survey.public_send(m) if survey.respond_to?(m) }
             .join(" ").downcase
    words = signal.scan(/[a-z]+/).map { |w| w.singularize }.to_set
    return STAR_RATING_ICON if words.empty?

    keywords, glyph = RATING_ICON_THEMES.max_by { |kw, _| (words & kw).size }
    return STAR_RATING_ICON if keywords.nil? || (words & keywords).empty?

    { on: glyph, off: glyph, kind: "emoji" }
  end

  # Minimal per-card, per-locale projection for the editor's inline
  # `#survey-cards-i18n` island. The language-tab JS (survey_editor_controller
  # _seedStore/_normContent) only reads text/description/options per locale, so
  # we deliberately omit image / option_images (multi-MB base64 data URLs) and
  # all structural fields. Without this, every uploaded image was serialised an
  # extra time into the inline <script> on each editor load — pure dead weight,
  # since the cards are already rendered once and carry their image on a data
  # attribute for autosave. Keeps the island to just the translatable text.
  def editor_cards_i18n(cards)
    Array(cards).map { |card| slim_card_i18n(card) }
  end

  def slim_card_i18n(card)
    card = card || {}
    out = {
      "text"        => card["text"],
      "description" => card["description"],
      "options"     => card["options"]
    }
    if card["i18n"].is_a?(Hash)
      out["i18n"] = card["i18n"].transform_values do |tr|
        tr = tr || {}
        { "text" => tr["text"], "description" => tr["description"], "options" => tr["options"] }.compact
      end
    end
    out.compact
  end

  # Returns a view of `card` with text/description/options in `locale`, falling
  # back per-field to the primary (default_locale) content. Structural fields
  # (type, image, allow_other, option count/order) are language-neutral and
  # preserved. Used by the player/preview to display a chosen language; the
  # editor renders the primary card directly.
  def localized_card(card, locale, default_locale = SupportedLocales::DEFAULT)
    return card if locale.blank? || locale.to_s == default_locale.to_s

    tr = card.dig("i18n", locale.to_s)
    return card unless tr.is_a?(Hash)

    base_opts = Array(card["options"])
    loc_opts  = Array(tr["options"])
    card.merge(
      "text"        => tr["text"].presence        || card["text"],
      "description" => tr["description"].presence  || card["description"],
      # Keep the primary array's length & order; fall back per slot.
      "options"     => base_opts.each_with_index.map { |o, i| loc_opts[i].presence || o }
    )
  end

  # All card-type metadata lives in config/card_types.yml. This helper
  # returns the symbol-keyed shape that the existing views were written
  # against, with a graceful fallback for unknown types.
  def card_type_meta(type)
    m = CardTypes.meta(type)
    return { badge: type.to_s.tr("_", " ").upcase, badge_css: "sb-range", q_label: "" } if m.empty?
    { badge: m["badge"], badge_css: m["badge_css"], q_label: m["panel_label"] }
  end

  # Images present under app/assets/images/verto-library/, grouped by
  # sub-folder (`backgrounds`, `left-panel`, `select-art`, `range-art`,
  # `swipe-cards`, `mobile-backgrounds`, ...). Each value is an array of
  # paths relative to verto-library/ (e.g. `backgrounds/landscape.jpg`),
  # ready to feed into `asset_path("verto-library/#{rel}")`. Files dropped
  # directly into verto-library/ are grouped under the empty-string key.
  # Picked up at request time so dropping a new file requires no rebuild.
  def verto_library_images
    dir = Rails.root.join("app/assets/images/verto-library")
    return {} unless Dir.exist?(dir)

    image_ext = /\.(jpe?g|png|webp|svg)\z/i
    grouped   = Hash.new { |h, k| h[k] = [] }

    Dir.children(dir).sort.each do |entry|
      full = dir.join(entry)
      if File.directory?(full)
        Dir.children(full).select { |f| f =~ image_ext }.sort.each do |fname|
          grouped[entry] << "#{entry}/#{fname}"
        end
      elsif entry =~ image_ext
        grouped[""] << entry
      end
    end

    grouped.reject { |_, files| files.empty? }
  end

  # Renders the organisation's uploaded logo if present, otherwise falls back
  # to the Playverto wordmark. `style` overrides the default sizing.
  def brand_logo_tag(organisation, style: "height:22px;width:auto;flex-shrink:0;", alt: nil)
    if organisation&.logo&.attached?
      image_tag(
        rails_blob_path(organisation.logo, only_path: true),
        style: "#{style};object-fit:contain;",
        alt:   alt || "#{organisation.name} logo"
      )
    else
      image_tag("playverto.svg", style: style, alt: alt || "Playverto")
    end
  end

  # Inline `style` value that sets the Verto-experience brand variables for a
  # given palette. Spread onto a wrapper element (player overlay, preview
  # overlay, editor card feed) so the brand colours are scoped to the Verto and
  # never leak into the Playverto platform chrome. Returns "" for the default
  # palette so un-branded Vertos fall back to the current Playverto look.
  def brand_palette_style_attr(palette)
    return "" if BrandPalette.default?(palette)

    r = BrandPalette.resolve(palette)
    {
      "--brand-primary"      => r["primary"],
      "--brand-cta"          => r["cta"],
      "--brand-bg"           => r["bg"],
      "--brand-cta-text"     => r["cta_text"],
      "--brand-cta-hover"    => r["cta_hover"],
      "--brand-text"         => r["text"],
      "--brand-surface"      => r["surface"],
      "--brand-surface-2"    => r["surface_2"],
      "--brand-primary-soft" => r["primary_soft"]
    }.map { |k, v| "#{k}:#{v}" }.join(";")
  end

  # Full backdrop style for a Verto's canvas wrappers (player overlay, preview
  # overlay, editor card feed): the brand-colour variables plus, when set, a
  # --brand-bg-image with a top/bottom scrim so the nav/footer text stays
  # legible over the image. Spread into the wrapper's inline `style`.
  #
  # `image:` lets the editor opt out of inlining the (potentially multi-MB
  # base64) --brand-bg-image here and instead define it ONCE on a shared
  # ancestor (see verto_brand_bg_image_var) — both the feed and the preview
  # overlay then inherit the var, so the data URL isn't materialised per-wrapper.
  # The palette + mobile vars stay scoped to the wrapper (the surrounding editor
  # chrome must NOT inherit brand colours), so those are always emitted.
  def verto_backdrop_style_attr(survey, image: true)
    parts = []
    palette = brand_palette_style_attr(survey.brand_palette)
    parts << palette if palette.present?
    parts << verto_brand_bg_image_var(survey) if image && survey.background_image.present?
    # Mobile-only per-card backdrop: a themed image picked from
    # verto-library/mobile-backgrounds/, applied behind a heavy white
    # scrim by the @media (max-width:767px) CSS on .split-card.
    if (mb = AssetPopulator.mobile_bg_url_for(survey)).present?
      parts << %(--mobile-card-bg: url("#{mb}"))
    end
    parts.join(";")
  end

  # Just the --brand-bg-image custom property (scrim gradient + the background
  # data URL), for defining once on a shared ancestor. Returns "" when no
  # background is set. Custom properties inherit, so wrappers that paint
  # `background-image: var(--brand-bg-image)` pick it up without re-inlining it.
  def verto_brand_bg_image_var(survey)
    return "" if survey.background_image.blank?
    url = survey.background_image.to_s.gsub(/["\r\n]/, "")
    %(--brand-bg-image: linear-gradient(rgba(0,0,0,0.45), rgba(0,0,0,0.12) 28%, rgba(0,0,0,0.12) 72%, rgba(0,0,0,0.45)), url("#{url}"))
  end

  def mini_preview_html(card)
    type = card["type"].to_s
    opts = Array(card["options"])
    bgs  = %w[mini-bg-1 mini-bg-2 mini-bg-3 mini-bg-4 mini-bg-5 mini-bg-6]

    html = case type
    when "range"
      dots = (0..4).map { |i| "<div class=\"mini-s-dot#{i.between?(1, 2) ? ' active' : ''}\"></div>" }.join
      "<div class=\"mini-tooltip\">Neutral</div>" \
      "<div class=\"mini-slider-track\">#{dots}" \
      "<div class=\"mini-s-thumb\"><div class=\"mini-s-line\"></div><div class=\"mini-s-line\"></div><div class=\"mini-s-line\"></div></div>" \
      "</div>"

    when "rating"
      stars = (0..4).map { |i| "<span class=\"mini-rating-star\" style=\"color:#{i < 3 ? '#FFCC00' : 'rgba(255,255,255,0.2)'}\">#{i < 3 ? '★' : '☆'}</span>" }.join
      "<div class=\"mini-rating-stars\">#{stars}</div>"

    when "multiple_choice", "select_many", "yes_no"
      items = type == "yes_no" ? %w[Yes No] : (opts.empty? ? [ "Option A", "Option B", "Option C" ] : opts.first(3))
      rows  = items.map.with_index { |o, i|
        sel = i == 0 ? " selected" : ""
        "<div class=\"mini-pick-item#{sel}\"><span class=\"mini-p-dot#{sel}\"></span>#{h(o.truncate(18))}</div>"
      }.join
      "<div class=\"mini-pick-list\">#{rows}</div>"

    when "select_one_grid", "select_many_grid"
      n    = opts.size
      cols = n >= 5 ? " cols-3" : ""
      cnt  = n >= 5 ? 6 : 4
      labels = %w[A B C D E F]
      cards  = cnt.times.map { |i|
        sel = i == 0 ? " selected" : ""
        "<div class=\"mini-img-card#{sel}\"><div class=\"mini-img-bg #{bgs[i % 6]}\"></div>" \
        "<div class=\"mini-img-ov\"></div><div class=\"mini-img-lbl\">#{labels[i]}</div></div>"
      }.join
      "<div class=\"mini-img-grid#{cols}\">#{cards}</div>"

    when "tap_card"
      "<div class=\"mini-swipe-stack\">" \
      "<div class=\"mini-swipe-card c1\"></div>" \
      "<div class=\"mini-swipe-card c2\"></div>" \
      "<div class=\"mini-swipe-card c3\"><span style=\"font-size:9px;color:rgba(0,0,0,0.5);padding:0 6px;text-align:center\">Swipe to respond</span></div>" \
      "</div>" \
      "<div class=\"mini-swipe-actions\">" \
      "<button class=\"mini-swipe-btn no\">✕</button>" \
      "<button class=\"mini-swipe-btn yes\">✓</button>" \
      "</div>"

    when "open_ended"
      "<textarea class=\"mini-textarea\" placeholder=\"Type your answer here…\" readonly></textarea>"

    else
      ""
    end

    html.html_safe
  end
end
