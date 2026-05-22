module ApplicationHelper
  # Returns a view of `card` with text/description/options in `locale`, falling
  # back per-field to the primary (default_locale) content. Structural fields
  # (type, nps_visual, image, allow_other, option count/order) are
  # language-neutral and preserved. Used by the player/preview to display a
  # chosen language; the editor renders the primary card directly.
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

  # Filenames present in app/assets/images/verto-library/. Picked up at request
  # time so dropping a new file in the folder requires no rebuild.
  def verto_library_images
    dir = Rails.root.join("app/assets/images/verto-library")
    return [] unless Dir.exist?(dir)
    Dir.children(dir).select { |f| f =~ /\.(jpe?g|png|webp|svg)\z/i }.sort
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
  def verto_backdrop_style_attr(survey)
    parts = []
    palette = brand_palette_style_attr(survey.brand_palette)
    parts << palette if palette.present?
    if survey.background_image.present?
      url = survey.background_image.to_s.gsub(/["\r\n]/, "")
      parts << %(--brand-bg-image: linear-gradient(rgba(0,0,0,0.45), rgba(0,0,0,0.12) 28%, rgba(0,0,0,0.12) 72%, rgba(0,0,0,0.45)), url("#{url}"))
    end
    parts.join(";")
  end

  def mini_preview_html(card)
    type = card["type"].to_s
    opts = Array(card["options"])
    bgs  = %w[mini-bg-1 mini-bg-2 mini-bg-3 mini-bg-4 mini-bg-5 mini-bg-6]

    html = case type
    when "range"
      dots = (0..4).map { |i| "<div class=\"mini-s-dot#{i.between?(1,2) ? ' active' : ''}\"></div>" }.join
      "<div class=\"mini-tooltip\">Neutral</div>" \
      "<div class=\"mini-slider-track\">#{dots}" \
      "<div class=\"mini-s-thumb\"><div class=\"mini-s-line\"></div><div class=\"mini-s-line\"></div><div class=\"mini-s-line\"></div></div>" \
      "</div>"

    when "rating"
      stars = (0..4).map { |i| "<span class=\"mini-rating-star\" style=\"color:#{i < 3 ? '#FFCC00' : 'rgba(255,255,255,0.2)'}\">#{i < 3 ? '★' : '☆'}</span>" }.join
      "<div class=\"mini-rating-stars\">#{stars}</div>"

    when "multiple_choice", "select_many", "yes_no"
      items = type == "yes_no" ? %w[Yes No] : (opts.empty? ? ["Option A", "Option B", "Option C"] : opts.first(3))
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
