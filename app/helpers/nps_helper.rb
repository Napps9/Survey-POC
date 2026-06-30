module NpsHelper
  # NPS is the classic 0–10 likelihood scale (the default), rendered as a
  # vertical "liquid container" the respondent drags to fill to their number.
  # The label set is editable, so a creator can use the traditional 0–10, a
  # shorter 4/5-point scale, or an agree/emotion range instead — the number of
  # steps follows the labels. NPS_STEPS is just the DEFAULT label count.
  NPS_STEPS = 11

  # The reactive Lottie animation (now used by the RANGE card, not NPS) has 5
  # frames; the range slider maps its position proportionally onto these. Kept
  # separate from NPS_STEPS so the two move independently.
  NPS_FRAMES = 5
  NPS_THEME  = "baseball".freeze # single global theme for v1; future theme picker swaps this

  def nps_card?(card)
    card["type"].to_s == "nps"
  end

  # Default 0–10 labels when a card hasn't set its own.
  def nps_default_labels
    (0..(NPS_STEPS - 1)).map(&:to_s)
  end

  # Asset URLs for the 5 reaction Lotties. Files live under
  # `app/assets/lottie/<theme>/` which Sprockets treats as an asset path root,
  # so files resolve at `/assets/<theme>/<file>`. Using asset_path so digested
  # URLs work in prod.
  def nps_lottie_urls
    (1..NPS_FRAMES).map { |i| asset_path("#{NPS_THEME}/#{i}.json") }
  end

  # LEFT panel: a div that the lottie-player Stimulus controller mounts into.
  # The full list of Lottie URLs is passed via data attribute so the JS doesn't
  # need to know about Rails asset digesting.
  def render_nps_reaction(initial_value: 1)
    content_tag :div, class: "nps-lottie",
                data: {
                  controller:                   "lottie-player",
                  "lottie-player-urls-value":   nps_lottie_urls.to_json,
                  "lottie-player-current-value": initial_value
                } do
      content_tag(:div, "", class: "nps-lottie-mount",
                  data: { "lottie-player-target" => "mount" })
    end
  end

  # RIGHT panel: the vertical "liquid container". The silhouette (`shape`) is
  # themed per Verto via a `nps-shape-*` class. `.nps-shape` carries the
  # container outline and clips the rising `.nps-track-fill` (driven by
  # --nps-fill set by the slider controller); `.nps-thumb` is the draggable
  # handle that shows the current value and sits OUTSIDE the clip so it's never
  # cut by the silhouette. `.nps-ticks` are the evenly-spaced step marks.
  def render_nps_control(shape: "pill", steps: NPS_STEPS)
    content_tag :div, class: "nps-control nps-shape-#{shape}", data: { axis: "vertical" } do
      concat(content_tag(:div, class: "nps-shape") do
        concat content_tag(:div, "", class: "nps-track-fill")
        concat(content_tag(:div, class: "nps-ticks") do
          safe_join(Array.new([ steps, 2 ].max) { content_tag(:div, "", class: "nps-tick") })
        end)
      end)
      concat content_tag(:div, content_tag(:span, "", class: "nps-thumb-val"), class: "nps-thumb")
    end
  end
end
