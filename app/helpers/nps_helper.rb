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

  # Asset URLs for the 5 Lotties + slider background. Files live under
  # `app/assets/lottie/<theme>/` which Sprockets treats as an asset path root,
  # so files resolve at `/assets/<theme>/<file>` (the "lottie" prefix is
  # implicit in the path root). Using asset_path so digested URLs work in prod.
  def nps_lottie_urls
    (1..NPS_STEPS).map { |i| asset_path("#{NPS_THEME}/#{i}.json") }
  end

  def nps_slider_bg_url
    asset_path("#{NPS_THEME}/slider.svg")
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

  # RIGHT panel: a vertical slider track with the dev-baked SVG as the visual.
  # `.nps-thumb` is the draggable handle positioned by the slider controller.
  def render_nps_control
    content_tag :div, class: "nps-control", data: { axis: "vertical" } do
      concat image_tag(nps_slider_bg_url, class: "nps-track-bg", alt: "")
      concat content_tag(:div, "", class: "nps-thumb")
    end
  end
end
