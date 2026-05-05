module ApplicationHelper
  CARD_TYPE_META = {
    "welcome_card"     => { badge: "WELCOME CARD", badge_css: "sb-welcome",  q_label: "" },
    "range"            => { badge: "RANGE",         badge_css: "sb-range",    q_label: "DRAG THE SLIDER" },
    "rating"           => { badge: "RATING",        badge_css: "sb-range",    q_label: "DRAG THE SLIDER" },
    "multiple_choice"  => { badge: "PICK ONE",      badge_css: "sb-range",    q_label: "CHOOSE ONE" },
    "select_many"      => { badge: "SELECT MANY",   badge_css: "sb-range",    q_label: "CHOOSE ALL THAT APPLY" },
    "yes_no"           => { badge: "YES / NO",      badge_css: "sb-range",    q_label: "CHOOSE ONE" },
    "select_one_grid"  => { badge: "IMAGE GRID",    badge_css: "sb-choice",   q_label: "CHOOSE ONE" },
    "select_many_grid" => { badge: "IMAGE GRID",    badge_css: "sb-choice",   q_label: "CHOOSE ALL THAT APPLY" },
    "tap_card"         => { badge: "SWIPE",         badge_css: "sb-swipe",    q_label: "SWIPE TO RESPOND" },
    "open_ended"       => { badge: "OPEN TEXT",     badge_css: "sb-text",     q_label: "TYPE YOUR ANSWER" },
    "static_page"      => { badge: "ACTIVITY",      badge_css: "sb-activity", q_label: "ACTIVITY" },
  }.freeze

  def card_type_meta(type)
    CARD_TYPE_META[type.to_s] || { badge: type.to_s.tr("_", " ").upcase, badge_css: "sb-range", q_label: "" }
  end

  # Interaction illustration shown in the left (dark) panel of each split-card.
  # Explains HOW to interact with the question type using a simple visual.
  def interaction_illustration(type)
    w = "color:rgba(255,255,255,0.9)"
    d = "color:rgba(255,255,255,0.45);font-size:11px;font-family:'ABeeZee',sans-serif;margin-top:8px;text-align:center;line-height:1.4"
    c = "font-family:'Alata',sans-serif"

    html = case type.to_s
    when "range", "rating"
      <<~HTML
        <div style="width:80%;display:flex;flex-direction:column;align-items:center;gap:10px;">
          <div style="display:flex;align-items:center;gap:8px;#{w}">
            <span style="font-size:16px;opacity:0.5;">←</span>
            <div style="position:relative;flex:1;height:6px;border-radius:3px;background:rgba(255,255,255,0.15);">
              <div style="position:absolute;width:40%;height:100%;border-radius:3px;background:#00A950;"></div>
              <div style="position:absolute;left:38%;top:50%;transform:translate(-50%,-50%);width:28px;height:28px;border-radius:50%;background:white;box-shadow:0 2px 8px rgba(0,0,0,0.3);display:flex;align-items:center;justify-content:center;">
                <svg width="10" height="10" viewBox="0 0 10 10"><path d="M3 5H1m6 0H9M5 3V1m0 8V7" stroke="#00A950" stroke-width="1.5" stroke-linecap="round"/></svg>
              </div>
            </div>
            <span style="font-size:16px;opacity:0.5;">→</span>
          </div>
          <div style="#{d}">Drag the slider to your answer</div>
        </div>
      HTML

    when "multiple_choice"
      items = [["◉", "Option A", true], ["○", "Option B", false], ["○", "Option C", false]]
      rows = items.map { |dot, label, sel|
        bg = sel ? "background:rgba(0,169,80,0.15);" : ""
        clr = sel ? "color:#00A950;" : "color:rgba(255,255,255,0.7);"
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
        bg = sel ? "background:rgba(0,169,80,0.12);" : ""
        clr = sel ? "color:#00A950;" : "color:rgba(255,255,255,0.6);"
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
            <div style="flex:1;padding:10px;border-radius:12px;background:#00A950;text-align:center;#{c};font-size:13px;color:white;">Yes</div>
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
        ring = sel ? "outline:2px solid #00A950;outline-offset:-2px;" : ""
        tick = sel ? "<div style=\"position:absolute;top:3px;right:4px;color:#00A950;font-size:10px;font-weight:700;\">✓</div>" : ""
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
            <span style="color:#00A950;#{c}">Yes →</span>
          </div>
          <div style="#{d}">Swipe cards left or right</div>
        </div>
      HTML

    when "open_ended"
      <<~HTML
        <div style="width:80%;display:flex;flex-direction:column;align-items:center;gap:10px;">
          <div style="width:100%;border:1px solid rgba(255,255,255,0.2);border-radius:10px;padding:10px 12px;background:rgba(255,255,255,0.04);">
            <div style="font-size:11px;color:rgba(255,255,255,0.3);font-family:'ABeeZee',sans-serif;">Type your answer…</div>
            <div style="height:2px;width:6px;background:#00A950;margin-top:6px;border-radius:2px;animation:blink 1s step-end infinite;"></div>
          </div>
          <div style="#{d}">Tap and type your response</div>
        </div>
      HTML

    when "static_page"
      <<~HTML
        <div style="width:80%;display:flex;flex-direction:column;align-items:center;gap:12px;">
          <div style="width:52px;height:52px;border-radius:50%;background:rgba(0,169,80,0.15);border:2px solid #00A950;display:flex;align-items:center;justify-content:center;">
            <span style="font-size:24px;">✓</span>
          </div>
          <div style="#{d}">Complete the activity then tap the checkbox</div>
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
      ""
    end

    html.html_safe
  end
end
