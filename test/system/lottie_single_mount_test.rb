require "application_system_test_case"

# A Lottie card must render its animation ONCE.
#
# lottie-web's loadAnimation APPENDS an <svg> to the container it is given, and
# lottie_player_controller's destroy() only clears the SVG that same controller
# instance created. So any <svg> already sitting in the mount when a fresh
# controller connects survives, and the new one stacks beneath it — two SVGs in
# a container whose `.card-lottie-mount svg` rule forces each to height:100%.
# The second copy hangs below the panel and is sheared off by .split-card's
# overflow:hidden, which is what a tester reported as a "weird glitch on some
# cards with lottiefiles" (18 Aug): the animation drawn twice, the lower copy
# cut off by the card's bottom edge.
#
# The mount reaches that state whenever a rendered card is re-attached rather
# than re-fetched — preview_verto_controller deep-clones one into the preview
# overlay, and a Turbo Drive cache restore puts a snapshot of one back on
# screen. Cloning is the reproducible half, so it is what this pins.
class LottieSingleMountTest < ApplicationSystemTestCase
  def setup
    super
    @org = Organisation.create!(name: "O", slug: "lsm-#{SecureRandom.hex(3)}")
    animation = {
      "v" => "5.7.4", "fr" => 30, "ip" => 0, "op" => 60, "w" => 200, "h" => 200,
      "layers" => [ { "ty" => 4, "nm" => "c", "ip" => 0, "op" => 60, "ks" => {},
                      "shapes" => [ { "ty" => "el", "p" => { "a" => 0, "k" => [ 100, 100 ] },
                                                    "s" => { "a" => 0, "k" => [ 120, 120 ] } } ] } ]
    }
    @survey = @org.surveys.create!(
      title: "LottieMount", theme: "Th", audience_age: "adults", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "welcome_card", "text" => "Welcome" } ]
    )
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(animation.to_json),
      filename: "card-lottie-#{SecureRandom.hex(8)}.json", content_type: "application/json"
    )
    @survey.card_images.attach(blob)
    cards = @survey.cards
    cards[0]["lottie"] = Rails.application.routes.url_helpers.rails_blob_path(blob, only_path: true)
    @survey.update!(cards: cards)
    @survey.update_columns(publish_token: SecureRandom.hex(8), test_token: SecureRandom.hex(8),
                           published_at: Time.current)
  end

  def mounted_svgs
    page.evaluate_script('document.querySelectorAll(".card-lottie-mount svg").length')
  end

  test "a Lottie card mounts exactly one animation on first render" do
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    assert_equal 1, mounted_svgs, "a freshly rendered card should hold one animation"
  end

  test "re-attaching an already-rendered card does not stack a second animation" do
    visit "/test/#{@survey.test_token}"
    dismiss_cookie_banner
    assert_equal 1, mounted_svgs

    # What preview_verto_controller does: clone a card that has ALREADY drawn
    # its <svg>, and let Stimulus connect a new controller over the clone.
    page.execute_script(<<~JS)
      const host = document.createElement("div")
      host.id = "clone-host"
      host.appendChild(document.querySelector(".card-lottie").cloneNode(true))
      document.body.appendChild(host)
    JS
    sleep 1.2 # the clone's controller has to connect and fetch the animation

    cloned = page.evaluate_script('document.querySelectorAll("#clone-host .card-lottie-mount svg").length')
    assert_equal 1, cloned,
                 "the clone stacked #{cloned} animations — loadAnimation appends, so the " \
                 "mount must be emptied before it runs"
  end

  # The twin bug on the same code path: show() early-returns when the value it
  # is asked for equals the one it last drew, so a controller that reconnects
  # without forgetting `shown` would skip the re-mount entirely and leave the
  # panel blank where destroy() had cleared the SVG.
  test "a card that disconnects and reconnects still shows its animation" do
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    assert_equal 1, mounted_svgs

    page.execute_script(<<~JS)
      const el = document.querySelector(".card-lottie")
      const parent = el.parentNode
      el.remove()                 // disconnect
      parent.appendChild(el)      // reconnect the SAME element
    JS
    sleep 1.2

    assert_equal 1, mounted_svgs, "the panel came back empty after a reconnect"
  end
end
