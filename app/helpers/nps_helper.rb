module NpsHelper
  # NPS is the classic 0–10 likelihood scale: 11 stops rendered as a centred
  # row of tappable number tiles (see the `nps` block in
  # shared/_card_component). The stored answer is the number itself (0–10).
  NPS_STEPS = 11

  # The reactive Lottie animation (now used by the RANGE card, not NPS) has 5
  # frames; the range slider maps its position proportionally onto these. Kept
  # separate from NPS_STEPS so the two scales move independently.
  NPS_FRAMES = 5
  NPS_THEME  = "baseball".freeze # single global theme for v1; future theme picker swaps this

  def nps_card?(card)
    card["type"].to_s == "nps"
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
end
