module ApplicationHelper
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

  # Interaction illustration shown in the left (dark) panel of each split-card.
  # Explains HOW to interact with the question type using a simple visual.
  def interaction_illustration(type)
    w = "color:rgba(255,255,255,0.9)"
    d = "color:rgba(255,255,255,0.45);font-size:11px;font-family:'ABeeZee',sans-serif;margin-top:8px;text-align:center;line-height:1.4"
    c = "font-family:'Alata',sans-serif"

    html = case type.to_s
    when "range"
      <<~HTML
        <div style="width:80%;display:flex;flex-direction:column;align-items:center;gap:10px;">
          <div style="display:flex;align-items:center;gap:8px;#{w}">
            <span style="font-size:16px;opacity:0.5;">←</span>
            <div style="position:relative;flex:1;height:6px;border-radius:3px;background:rgba(255,255,255,0.15);">
              <div style="position:absolute;width:40%;height:100%;border-radius:3px;background:var(--brand-primary,#01EACB);"></div>
              <div style="position:absolute;left:38%;top:50%;transform:translate(-50%,-50%);width:28px;height:28px;border-radius:50%;background:white;box-shadow:0 2px 8px rgba(0,0,0,0.3);display:flex;align-items:center;justify-content:center;">
                <svg width="10" height="10" viewBox="0 0 10 10"><path d="M3 5H1m6 0H9M5 3V1m0 8V7" stroke-width="1.5" stroke-linecap="round" style="stroke:var(--brand-primary,#01EACB)"/></svg>
              </div>
            </div>
            <span style="font-size:16px;opacity:0.5;">→</span>
          </div>
          <div style="#{d}">Drag the slider to your answer</div>
        </div>
      HTML

    when "rating"
      <<~HTML
        <div style="width:80%;display:flex;flex-direction:column;align-items:center;gap:12px;">
          <div style="display:flex;gap:8px;">
            #{ (0..4).map { |i| "<span style=\"font-size:34px;line-height:1;#{i < 3 ? "color:#FFCC00;" : "color:rgba(255,255,255,0.2);"}\">#{i < 3 ? "★" : "☆"}</span>" }.join }
          </div>
          <div style="#{d}">Tap a star to rate</div>
        </div>
      HTML

    when "multiple_choice"
      items = [["◉", "Option A", true], ["○", "Option B", false], ["○", "Option C", false]]
      rows = items.map { |dot, label, sel|
        bg = sel ? "background:var(--brand-primary-soft,rgba(1,234,203,0.15));" : ""
        clr = sel ? "color:var(--brand-primary,#01EACB);" : "color:rgba(255,255,255,0.7);"
        "<div style=\"display:flex;align-items:center;gap:8px;padding:6px 10px;border-radius:8px;#{bg}\">" \
        "<span style=\"font-size:14px;#{clr}\">#{dot}</span>" \
        "<span style=\"font-size:12px;#{clr}#{c}\">#{label}</span></div>"
      }.join
      <<~HTML
        <div style="width:80%;display:flex;flex-direction:column;gap:4px;">
          #{rows}
          <div style="#{d};margin-top:4px;">Tap one option to select</div>
        </div>
      HTML

    when "select_many"
      items = [["☑", "Option A", true], ["☑", "Option B", true], ["☐", "Option C", false]]
      rows = items.map { |dot, label, sel|
        bg = sel ? "background:var(--brand-primary-soft,rgba(1,234,203,0.12));" : ""
        clr = sel ? "color:var(--brand-primary,#01EACB);" : "color:rgba(255,255,255,0.6);"
        "<div style=\"display:flex;align-items:center;gap:8px;padding:6px 10px;border-radius:8px;#{bg}\">" \
        "<span style=\"font-size:14px;#{clr}\">#{dot}</span>" \
        "<span style=\"font-size:12px;#{clr}#{c}\">#{label}</span></div>"
      }.join
      <<~HTML
        <div style="width:80%;display:flex;flex-direction:column;gap:4px;">
          #{rows}
          <div style="#{d};margin-top:4px;">Tap all that apply</div>
        </div>
      HTML

    when "yes_no"
      <<~HTML
        <div style="width:80%;display:flex;flex-direction:column;align-items:center;gap:12px;">
          <div style="display:flex;gap:12px;width:100%;">
            <div style="flex:1;padding:10px;border-radius:12px;background:var(--brand-primary,#01EACB);text-align:center;#{c};font-size:13px;color:white;">Yes</div>
            <div style="flex:1;padding:10px;border-radius:12px;background:rgba(255,255,255,0.08);text-align:center;#{c};font-size:13px;color:rgba(255,255,255,0.5);">No</div>
          </div>
          <div style="#{d}">Tap to choose one</div>
        </div>
      HTML

    when "select_one_grid", "select_many_grid"
      multi = type.to_s == "select_many_grid"
      cells = ["A","B","C","D"].map.with_index { |l, i|
        bg = %w[#d4edda #d1ecf1 #fff3cd #f8d7da][i]
        sel = i.zero? || (multi && i == 1)
        ring = sel ? "outline:2px solid var(--brand-primary,#01EACB);outline-offset:-2px;" : ""
        tick = sel ? "<div style=\"position:absolute;top:3px;right:4px;color:var(--brand-primary,#01EACB);font-size:10px;font-weight:700;\">✓</div>" : ""
        "<div style=\"position:relative;height:44px;border-radius:8px;background:#{bg};display:flex;align-items:center;justify-content:center;#{ring}\">" \
        "<span style=\"font-size:11px;color:rgba(0,0,0,0.55);font-family:'Alata',sans-serif;\">#{l}</span>#{tick}</div>"
      }.join
      action = multi ? "Tap all that apply" : "Tap one image to select"
      <<~HTML
        <div style="width:80%;display:flex;flex-direction:column;gap:8px;">
          <div style="display:grid;grid-template-columns:1fr 1fr;gap:6px;">#{cells}</div>
          <div style="#{d}">#{action}</div>
        </div>
      HTML

    when "tap_card"
      <<~HTML
        <div style="width:80%;display:flex;flex-direction:column;align-items:center;gap:10px;">
          <div style="position:relative;height:72px;width:100%;">
            <div style="position:absolute;left:4px;top:8px;width:70%;height:58px;border-radius:12px;background:rgba(255,255,255,0.06);transform:rotate(-4deg);"></div>
            <div style="position:absolute;left:8px;top:4px;width:72%;height:58px;border-radius:12px;background:rgba(255,255,255,0.10);transform:rotate(-2deg);"></div>
            <div style="position:absolute;left:12px;top:0;width:74%;height:60px;border-radius:12px;background:rgba(255,255,255,0.88);display:flex;align-items:center;justify-content:center;">
              <span style="font-size:11px;color:rgba(0,0,0,0.5);font-family:'ABeeZee',sans-serif;">Statement to react to</span>
            </div>
          </div>
          <div style="display:flex;justify-content:space-between;width:90%;font-size:11px;">
            <span style="color:#e05555;#{c}">← No</span>
            <span style="color:var(--brand-primary,#01EACB);#{c}">Yes →</span>
          </div>
          <div style="#{d}">Swipe cards left or right</div>
        </div>
      HTML

    when "open_ended"
      <<~HTML
        <div style="width:80%;display:flex;flex-direction:column;align-items:center;gap:10px;">
          <div style="width:100%;border:1px solid rgba(255,255,255,0.2);border-radius:10px;padding:10px 12px;background:rgba(255,255,255,0.04);">
            <div style="font-size:11px;color:rgba(255,255,255,0.3);font-family:'ABeeZee',sans-serif;">Type your answer…</div>
            <div style="height:2px;width:6px;background:var(--brand-primary,#01EACB);margin-top:6px;border-radius:2px;animation:blink 1s step-end infinite;"></div>
          </div>
          <div style="#{d}">Tap and type your response</div>
        </div>
      HTML

    else  # welcome_card
      <<~HTML
        <div style="width:80%;display:flex;flex-direction:column;align-items:center;gap:12px;">
          <div style="font-size:40px;line-height:1;">👋</div>
          <div style="#{d}">Read the intro — no answer needed</div>
        </div>
      HTML
    end

    html.html_safe
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
