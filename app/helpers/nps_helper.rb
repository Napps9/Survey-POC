module NpsHelper
  # 5-step NPS scale (1-5). Each value has a corresponding Lottie animation
  # on the left panel; the right panel is a vertical slider sitting on top of
  # a static SVG background. The slider dispatches `nps:valueChanged` events
  # which the lottie-player controller listens for to swap animations.
  NPS_STEPS = 5
  NPS_THEME = "baseball".freeze  # single global theme for v1; future theme picker swaps this

  def nps_card?(card)
    card["type"].to_s == "nps"
  end

  # Asset URLs for the 5 Lotties. Files live under `app/assets/lottie/<theme>/`
  # which Sprockets treats as an asset path root, so files resolve at
  # `/assets/<theme>/<file>` (the "lottie" prefix is implicit in the path root).
  # Using asset_path so digested URLs work in prod.
  def nps_lottie_urls
    (1..NPS_STEPS).map { |i| asset_path("#{NPS_THEME}/#{i}.json") }
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

  # RIGHT panel: a vertical pill slider. The pill outline and clipping come
  # from CSS on `.nps-control`; `.nps-track-fill` rises from the bottom up to
  # the thumb position as the value increases (driven by --nps-fill set by the
  # slider controller); `.nps-thumb` is the draggable handle.
  def render_nps_control
    content_tag :div, class: "nps-control", data: { axis: "vertical" } do
      concat content_tag(:div, "", class: "nps-track-fill")
      concat content_tag(:div, "", class: "nps-thumb")
    end
  end
end
