module ApplicationHelper
  # Maps survey card types to badge label + CSS class + question eyebrow label
  CARD_TYPE_META = {
    "welcome_card"     => { badge: "WELCOME CARD", badge_css: "sb-welcome",  q_label: "" },
    "range"            => { badge: "RANGE",         badge_css: "sb-range",    q_label: "DRAG THE SLIDER" },
    "rating"           => { badge: "RANGE",         badge_css: "sb-range",    q_label: "DRAG THE SLIDER" },
    "multiple_choice"  => { badge: "PICK ONE",      badge_css: "sb-range",    q_label: "CHOOSE ONE" },
    "select_many"      => { badge: "PICK MANY",     badge_css: "sb-range",    q_label: "CHOOSE ALL THAT APPLY" },
    "yes_no"           => { badge: "PICK ONE",      badge_css: "sb-range",    q_label: "CHOOSE ONE" },
    "select_one_grid"  => { badge: "IMAGE CHOICE",  badge_css: "sb-choice",   q_label: "CHOOSE ONE" },
    "select_many_grid" => { badge: "IMAGE CHOICE",  badge_css: "sb-choice",   q_label: "CHOOSE MANY" },
    "tap_card"         => { badge: "SWIPE",         badge_css: "sb-swipe",    q_label: "SWIPE TO RESPOND" },
    "open_ended"       => { badge: "OPEN TEXT",     badge_css: "sb-text",     q_label: "TYPE YOUR ANSWER" },
    "static_page"      => { badge: "ACTIVITY",      badge_css: "sb-activity", q_label: "ACTIVITY" },
  }.freeze

  def card_type_meta(type)
    CARD_TYPE_META[type.to_s] || { badge: type.to_s.tr("_", " ").upcase, badge_css: "sb-range", q_label: "" }
  end

  def mini_preview_html(card)
    type = card["type"].to_s
    opts = Array(card["options"])
    bgs  = %w[mini-bg-1 mini-bg-2 mini-bg-3 mini-bg-4 mini-bg-5 mini-bg-6]

    html = case type
    when "range", "rating"
      dots = (0..4).map { |i| "<div class=\"mini-s-dot#{i.between?(1,2) ? ' active' : ''}\"></div>" }.join
      "<div class=\"mini-tooltip\">Neutral</div>" \
      "<div class=\"mini-slider-track\">#{dots}" \
      "<div class=\"mini-s-thumb\"><div class=\"mini-s-line\"></div><div class=\"mini-s-line\"></div><div class=\"mini-s-line\"></div></div>" \
      "</div>"

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

    when "static_page"
      "<div style=\"width:100%;display:flex;align-items:flex-start;gap:8px;padding:8px 10px;border-radius:10px;background:rgba(255,255,255,0.05)\">" \
      "<div style=\"width:16px;height:16px;border-radius:4px;background:#00A950;flex-shrink:0;display:flex;align-items:center;justify-content:center\">" \
      "<svg width=\"8\" height=\"6\" viewBox=\"0 0 12 9\" fill=\"white\"><path d=\"M3.712 7.295L1.21 4.79C.931 4.511.488 4.511.209 4.79-.07 5.069-.07 5.513.209 5.792L3.205 8.791c.278.279.729.279 1.008 0L11.791 1.211c.279-.279.279-.723 0-1.002-.279-.279-.722-.279-1.001 0z\"/></svg>" \
      "</div><div style=\"font-size:9px;color:rgba(255,255,255,0.55);line-height:1.4\">Complete the activity</div></div>"

    else
      # welcome_card — empty
      ""
    end

    html.html_safe
  end
end
