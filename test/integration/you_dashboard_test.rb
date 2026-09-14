require "test_helper"

# The respondent dashboard: one card per Verto, four numbers above them, and
# the two sections that only exist when there is something to put in them.
#
# The property that carries the file is the primary button. A card offers
# EXACTLY ONE thing to press for — Compare when the comparison is open, Share
# when sharing is what would open it, nothing when the Verto is closed and can
# no longer be played — so a respondent is never offered two buttons of equal
# weight, and never a button whose destination is the sentence explaining why
# it leads nowhere. Everything else here is the page reading the account
# correctly: a retake is one card, a follow-up is offered once, an impact is
# listed before a promise, and none of it costs a query per card.
class YouDashboardTest < ActionDispatch::IntegrationTest
  CARDS = [
    { "type" => "welcome_card", "cid" => "w", "text" => "Hello" },
    { "type" => "multiple_choice", "cid" => "q", "text" => "What would you want first?",
      "options" => [ "Wider pavements", "More trees", "Somewhere to sit" ] },
    { "type" => "yes_no", "cid" => "y", "text" => "Again?", "options" => %w[Yes No] }
  ].freeze

  NEEDED = Response::MIN_REGION_SAMPLE_SIZE

  def org(name = "Haverley") = Organisation.create!(name: name, slug: "yd-#{SecureRandom.hex(3)}")

  def survey(owner: nil, cards: CARDS, **attrs)
    (owner || org).surveys.create!(
      title: "T", theme: "Car-free High Street", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ], cards: cards.map(&:dup),
      show_results_comparison: true,
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current, **attrs)
  end

  def answered(s, tokens: nil, at: 1.day.ago, key: nil)
    s.responses.create!(session_token: SecureRandom.uuid, status: "completed", answered: true,
                        completed_at: at,
                        answers: { "1" => { "type" => "multiple_choice", "value" => "More trees" } },
                        token_totals: tokens || {},
                        player_key_digest: key ? s.player_key_digest(key) : nil)
  end

  def crowd(s, n) = n.times { answered(s) }

  def with_impact(s, published: true)
    s.update!(impact_headline: "The High Street closes at weekends from March",
              impact_body: "62% wanted a weekend closure.",
              impact_changes: [ "Deliveries move to a 7–10am window" ],
              impact_published_at: (published ? 3.days.ago : nil))
    s
  end

  def with_promise(s) = s.tap { |x| x.update!(next_step_headline: "The council decides on 14 October") }

  def sign_in_with(claims)
    pl = Player.for_email("yd-#{SecureRandom.hex(4)}@test.com")
    _link, raw = PlayerSignInLink.mint!(
      player: pl, claim_payload: claims.map { |r| { "response_id" => r.id, "source" => "signup" } })
    post player_sign_in_path(raw)
    pl
  end

  # The cards in the Vertos section only: the follow-up and impact sections
  # draw .you-verto too, and a count over the page would blur them together.
  def cards = css_select("#vertos .you-verto")

  # ── The tiles ─────────────────────────────────────────────────────────────

  test "the four tiles count Vertos, open results, impact updates and the wallet total" do
    o = org
    ready    = survey(owner: o)
    thin     = survey(owner: o, tokenisation_enabled: true,
                      token_types: [ { "id" => "leaf", "name" => "Leaves", "icon" => "🍃" } ])
    impacted = with_impact(survey(owner: o, show_results_comparison: false))
    promised = with_promise(survey(owner: o, show_results_comparison: false))
    crowd(ready, NEEDED)
    sign_in_with([ answered(ready), answered(thin, tokens: { "leaf" => 40 }),
                   answered(impacted), answered(promised) ])

    get you_path

    assert_response :success
    values = css_select(".you-tile .you-tile-value").map { |e| e.text.strip }
    # Vertos, results open, impact updates (a written impact AND a promise
    # both count — both are news), collected.
    assert_equal %w[4 1 2 40], values
    assert_select ".you-tile.is-yellow .you-tile-label", text: I18n.t("you.tile_collected")
    assert_select "a.you-tile.is-yellow[href=?]", you_wallet_path, 1
  end

  test "the collected tile is not a link to an empty wallet" do
    sign_in_with([ answered(survey) ])

    get you_path

    assert_select ".you-tile.is-yellow .you-tile-value", text: "0"
    assert_select "a.you-tile", 0
  end

  # ── One card per Verto ────────────────────────────────────────────────────

  test "two runs of the same Verto are one card, with the piles summed and the newer date" do
    s = survey(tokenisation_enabled: true,
               token_types: [ { "id" => "leaf", "name" => "Leaves", "icon" => "🍃" } ])
    first  = answered(s, tokens: { "leaf" => 5 }, at: 40.days.ago)
    retake = answered(s, tokens: { "leaf" => 7 }, at: 2.days.ago)
    sign_in_with([ first, retake ])

    get you_path

    assert_equal 1, cards.size
    assert_select "#vertos .you-pile", text: /🍃\s*12\s*Leaves/
    assert_select ".you-tile.is-teal .you-tile-value", text: "1"
    assert_select "#vertos .you-verto-when",
                  text: I18n.t("you.played_on", date: I18n.l(retake.completed_at.to_date, format: :long))
    assert_select "#vertos .you-verto-when",
                  text: I18n.t("you.played_on", date: I18n.l(first.completed_at.to_date, format: :long)),
                  count: 0
  end

  # ── The primary button ────────────────────────────────────────────────────

  test "an open comparison leads, with Share stepped down to a ghost" do
    s = survey
    crowd(s, NEEDED)
    sign_in_with([ answered(s) ])

    get you_path

    card = cards.first
    assert_equal 1, card.css("a.you-cta-primary").size
    primary = card.css("a.you-cta-primary.you-cta-compare").first
    assert primary, "the primary is Compare"
    assert_equal you_verto_path(s, anchor: "compare"), primary["href"]
    assert_match I18n.t("you.cta_compare"), primary.text
    ghost = card.css("a.you-cta-ghost.you-cta-share").first
    assert ghost, "Share is offered, as a ghost"
    assert_equal play_survey_url(s.publish_token), ghost["href"]
    assert_equal "share-verto", ghost["data-controller"]
    assert_select "#vertos .you-verto-badge", text: I18n.t("you.badge_results_open")
    assert_select "#vertos .you-verto-note", 0
    assert_select "#vertos .you-verto.is-quiet", 0
  end

  test "under the floor, sharing is what opens the results, so Share leads with the bar" do
    s = survey
    crowd(s, 1)
    sign_in_with([ answered(s) ])

    get you_path

    card = cards.first
    assert_equal 1, card.css("a.you-cta-primary").size
    primary = card.css("a.you-cta-primary.you-cta-share").first
    assert primary
    assert_match I18n.t("you.cta_share_unlock"), primary.text
    assert_equal play_survey_url(s.publish_token), primary["href"]
    assert_equal "share-verto", primary["data-controller"]
    assert_select "#vertos .you-verto-note",
                  text: I18n.t("you.compare_pending", needed: NEEDED, have: 2)
    assert_select "#vertos .you-track .you-fill[style=?]", "width:#{(2 * 100.0 / NEEDED).round}%"
    assert_select "#vertos .you-verto.is-quiet", 1
    assert_select "#vertos .you-verto-badge", text: I18n.t("you.badge_played")
    # No second Share: the primary IS the share.
    assert_equal 1, card.css("a.you-cta-share").size
  end

  test "one answer short, the note says so rather than restating the floor" do
    s = survey
    crowd(s, NEEDED - 2)
    sign_in_with([ answered(s) ])

    get you_path

    assert_select "#vertos .you-verto-note",
                  text: I18n.t("you.compare_one_more", have: NEEDED - 1, needed: NEEDED)
    assert_select "#vertos .you-verto-note",
                  text: I18n.t("you.compare_pending", needed: NEEDED, have: NEEDED - 1), count: 0
  end

  test "a closed comparison still leads with Share, and says the results are closed" do
    s = survey(show_results_comparison: false)
    crowd(s, NEEDED)
    sign_in_with([ answered(s) ])

    get you_path

    card = cards.first
    assert_equal 1, card.css("a.you-cta-primary").size
    primary = card.css("a.you-cta-primary.you-cta-share").first
    assert primary
    assert_match I18n.t("you.cta_share"), primary.text
    refute_match I18n.t("you.cta_share_unlock"), primary.text
    assert_select "#vertos .you-verto-note", text: I18n.t("you.compare_closed", org: s.organisation.name)
    assert_select "#vertos .you-track", 0
  end

  test "closed and no longer playable, a card has no primary at all — only the impact ghost" do
    s = survey(show_results_comparison: false)
    sign_in_with([ answered(s) ])
    s.update!(unpublished_at: Time.current)
    refute s.reload.playable?

    get you_path

    card = cards.first
    assert_equal 0, card.css("a.you-cta-primary").size
    assert_equal 0, card.css("a.you-cta-share").size
    assert_equal 1, card.css("a.you-cta").size
    ghost = card.css("a.you-cta-ghost.you-cta-impact").first
    assert_equal you_verto_path(s, anchor: "impact"), ghost["href"]
    assert_equal I18n.t("you.cta_impact_short"), ghost.text.strip
    # The card still opens — they kept it, and keeping it is the point.
    assert_select "#vertos a.you-verto-link[href=?]", you_verto_path(s)
  end

  test "exactly one primary per card, whatever the mix" do
    o = org
    ready  = survey(owner: o)
    thin   = survey(owner: o, theme: "Too few")
    closed = survey(owner: o, theme: "Shut", show_results_comparison: false)
    gone   = survey(owner: o, theme: "Gone", show_results_comparison: false)
    crowd(ready, NEEDED)
    crowd(closed, NEEDED)
    sign_in_with([ answered(ready), answered(thin), answered(closed), answered(gone) ])
    gone.update!(unpublished_at: Time.current)

    get you_path

    assert_equal 4, cards.size
    cards.each do |card|
      title = card.css(".you-verto-title").text.strip
      assert_operator card.css("a.you-cta-primary").size, :<=, 1, "#{title}: more than one primary"
    end
    assert_select "#vertos a.you-cta-primary", 3
    assert_select "#vertos a.you-cta-primary.you-cta-compare", 1
    assert_select "#vertos a.you-cta-primary.you-cta-share", 2
  end

  # ── The badge and the impact ghost ────────────────────────────────────────

  test "the badge names the one thing that is true of the Verto, impact first" do
    o = org
    impacted = with_impact(survey(owner: o))
    promised = with_promise(survey(owner: o, theme: "Promised"))
    crowd(impacted, NEEDED)
    crowd(promised, NEEDED)
    sign_in_with([ answered(impacted), answered(promised) ])

    get you_path

    badges = cards.to_h { |c| [ c.css(".you-verto-title").text.strip, c.css(".you-verto-badge").text.strip ] }
    # Both comparisons are open; the badge still says impact, because that is
    # the rarer and the better news.
    assert_equal I18n.t("you.badge_impact"), badges["Car-free High Street"]
    assert_equal I18n.t("you.badge_next_step"), badges["Promised"]
    assert_select "#vertos .you-verto.is-impact", 1
    assert_select "#vertos .you-verto.is-promise", 1
  end

  test "the impact ghost is tinted purple for a written impact and amber for a promise" do
    o = org
    impacted = with_impact(survey(owner: o))
    promised = with_promise(survey(owner: o, theme: "Promised"))
    plain    = survey(owner: o, theme: "Plain")
    sign_in_with([ answered(impacted), answered(promised), answered(plain) ])

    get you_path

    assert_select "#vertos .you-verto.is-impact a.you-cta-impact.you-cta-tint-purple[href=?]",
                  you_verto_path(impacted, anchor: "impact"), text: /#{I18n.t("you.cta_what_changed")}/
    assert_select "#vertos .you-verto.is-promise a.you-cta-impact.you-cta-tint-amber[href=?]",
                  you_verto_path(promised, anchor: "impact"), text: /#{I18n.t("you.next_step_title")}/
    assert_select "#vertos .you-verto:not(.is-impact):not(.is-promise) a.you-cta-impact",
                  text: I18n.t("you.cta_impact_short")
    assert_select "#vertos a.you-cta-impact.you-cta-tint-purple", 1
    assert_select "#vertos a.you-cta-impact.you-cta-tint-amber", 1
  end

  # ── What's next ───────────────────────────────────────────────────────────

  test "follow-ups are one section, each offered once with its reason, never one already held" do
    o = org
    first  = survey(owner: o, theme: "First")
    second = survey(owner: o, theme: "Second")
    fresh  = survey(owner: o, theme: "High Street, one year on")
    held   = survey(owner: o, theme: "Already done this one")
    # Both held Vertos point at the same fresh one, and one of them at a
    # Verto the account already holds.
    first.update!(follow_up_survey_ids: [ fresh.id, held.id ])
    second.update!(follow_up_survey_ids: [ fresh.id ])
    sign_in_with([ answered(second, at: 3.days.ago), answered(first, at: 1.day.ago), answered(held) ])

    get you_path

    assert_select "#next .you-verto.is-next", 1
    assert_select "#next .you-verto-title", text: "High Street, one year on"
    assert_select "#next .you-verto-title", text: "Already done this one", count: 0
    # The reason is the Verto they played most recently of the two that point.
    assert_select "#next .you-verto-because", text: I18n.t("you.next_because", verto: "First")
    assert_select "#next .you-section-count", text: "1"
    assert_select "#next .you-verto-badge", text: I18n.t("you.badge_follow_up")
    assert_select "#next .you-verto-when", text: I18n.t("you.questions", count: 2)
    assert_select "#next a.you-cta-primary.you-cta-play[href=?]", play_survey_path(fresh.publish_token),
                  text: /#{I18n.t("you.cta_play")}/
    # And the held cards carry no strip of their own any more.
    assert_select "#vertos .you-followups", 0
  end

  test "with nothing pointed at, there is no What's next section" do
    sign_in_with([ answered(survey) ])

    get you_path

    assert_select "#next", 0
    assert_select ".you-section-label", text: I18n.t("you.section_next"), count: 0
  end

  # ── What your answers did ─────────────────────────────────────────────────

  test "impacts are listed before promises, each with its count and its date" do
    o = org
    promised = with_promise(survey(owner: o, theme: "Promised"))
    impacted = with_impact(survey(owner: o, theme: "Done"))
    crowd(impacted, 3)
    # The promise was played more recently, so it leads the Vertos grid —
    # and still comes second here.
    sign_in_with([ answered(promised, at: 1.day.ago), answered(impacted, at: 5.days.ago) ])

    get you_path

    titles = css_select("#impact .you-impact-card .you-verto-org").map { |e| e.text.strip }
    assert_equal [ "#{o.name} · Done", "#{o.name} · Promised" ], titles
    assert_select "#impact .you-impact-card.is-impact .you-impact-headline",
                  text: "The High Street closes at weekends from March"
    assert_select "#impact .you-impact-card.is-impact .you-impact-change", text: /Deliveries move/
    assert_select "#impact .you-impact-card.is-impact .you-verto-note",
                  text: /#{Regexp.escape(I18n.t("you.have_answered", count: 4))}.*#{Regexp.escape(I18n.t("you.impact_published_on", date: I18n.l(impacted.impact_published_at.to_date, format: :long)))}/m
    assert_select "#impact .you-impact-card.is-impact a.you-cta-tint-purple[href=?]",
                  you_verto_path(impacted, anchor: "impact"), text: /#{I18n.t("you.cta_read_impact")}/
    assert_select "#impact .you-impact-card.is-promise .you-impact-headline",
                  text: "The council decides on 14 October"
    assert_select "#impact .you-impact-card.is-promise .you-verto-note",
                  text: /#{Regexp.escape(I18n.t("you.have_answered", count: 1))}.*#{Regexp.escape(I18n.t("you.promise_meta"))}/m
    assert_select "#impact .you-impact-card.is-promise a.you-cta-tint-purple", 0
    assert_select "#impact .you-section-count", text: "2"
    # No primary anywhere in this section: reading is not an action on par
    # with comparing.
    assert_select "#impact a.you-cta-primary", 0
  end

  test "an unpublished impact is not news, and nothing written is no section" do
    o = org
    drafted = with_impact(survey(owner: o), published: false)
    plain   = survey(owner: o)
    sign_in_with([ answered(drafted), answered(plain) ])

    get you_path

    assert_select "#impact", 0
    assert_select ".you-tile.is-purple .you-tile-value", text: "0"
    assert_select "#vertos .you-verto.is-impact", 0
  end

  # ── The beta strip ────────────────────────────────────────────────────────
  #
  # It is rendered from you/_bar rather than from this page, and that is the
  # property worth pinning: it has to be on all four account pages, the wallet
  # above all — that is where a respondent meets a token total with nothing to
  # spend it on, and the strip is the sentence that answers them. Drawn before
  # the bar, because a notice below the thing it is about is a footnote.

  test "the beta strip is above the bar on every account page" do
    s = survey
    sign_in_with([ answered(s) ])

    [ you_path, you_wallet_path, you_account_path, you_verto_path(s.id) ].each do |path|
      get path

      assert_response :success, path
      assert_select ".you-beta .you-beta-tag", { text: I18n.t("you.beta_tag"), count: 1 }, path
      assert_select ".you-beta .you-beta-text", { text: I18n.t("you.beta_note"), count: 1 }, path
      assert_operator response.body.index("you-beta"), :<, response.body.index("you-topbar"),
                      "#{path}: the strip is drawn below the bar"
    end
  end

  # ── The strip, the states, the cover ──────────────────────────────────────

  test "the three steps are drawn, and the share step names the floor" do
    sign_in_with([ answered(survey) ])

    get you_path

    assert_select ".you-steps h2.you-steps-title", text: I18n.t("you.count_title")
    assert_select ".you-steps li.you-step", 3
    assert_select ".you-steps .you-step-n", text: "2"
    assert_select ".you-steps .you-step-body", text: I18n.t("you.step_share_body", needed: NEEDED)
    assert_select ".you-steps .you-step-title", text: I18n.t("you.step_impact_title")
  end

  test "signed out there is a bar with no account button, and the page that explains" do
    get you_path

    assert_response :success
    assert_select ".you-topbar", 1
    assert_select ".you-account-btn", 0
    assert_select ".you-topbar-centre", 0
    # The strip stays: someone deciding whether to give an address at the end
    # of a Verto is exactly who the promise in it is addressed to.
    assert_select ".you-beta .you-beta-text", text: I18n.t("you.beta_note")
    assert_select "h1.you-h1", text: I18n.t("you.signed_out_title")
    assert_select ".you-tiles", 0
    assert_select ".you-steps", 0
  end

  test "an empty account gets the empty line, the zeros and the steps" do
    sign_in_with([])

    get you_path

    assert_response :success
    assert_select "#vertos .you-verto", 0
    assert_select "#vertos .you-card .you-sub", text: I18n.t("you.empty")
    assert_equal %w[0 0 0 0], css_select(".you-tile-value").map { |e| e.text.strip }
    assert_select ".you-steps li.you-step", 3
    assert_select ".you-account-btn", 1
  end

  test "a Verto with a welcome-card image wears it; one without gets the plain band" do
    o = org
    dressed = survey(owner: o, theme: "Dressed",
                     cards: [ { "type" => "welcome_card", "cid" => "w", "text" => "Hi",
                                "image" => "https://images.example/cover.jpg" } ] + CARDS.drop(1))
    plain   = survey(owner: o, theme: "Plain")
    sign_in_with([ answered(dressed), answered(plain) ])

    get you_path

    covers = cards.to_h { |c| [ c.css(".you-verto-title").text.strip, c.css(".you-verto-cover").first ] }
    assert_includes covers["Dressed"]["style"], "background-image:url('https://images.example/cover.jpg')"
    assert_nil covers["Plain"]["style"]
    assert_select "#vertos .you-verto-cover", 2
  end

  # ── What it costs ─────────────────────────────────────────────────────────

  test "the compare reasons and the answered counts cost one grouped COUNT however many Vertos" do
    # The page lists every Verto an account holds, so a per-card count is a
    # per-card query. Counted rather than asserted by eye: the batching is the
    # whole reason both the note and the "N answered" line can live on it.
    o = org
    claims = 5.times.map do
      s = survey(owner: o)
      crowd(s, 1)
      answered(s)
    end
    sign_in_with(claims)

    counts = 0
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      counts += 1 if payload[:sql].to_s.match?(/COUNT\(\*\).*"responses"/i)
    end
    get you_path
    ActiveSupport::Notifications.unsubscribe(sub)

    assert_select "#vertos .you-verto-note", 5
    assert_select "#vertos .you-verto-stat", text: I18n.t("you.answered", count: 2), count: 5
    assert_equal 1, counts, "expected one grouped COUNT over responses for the whole page, got #{counts}"
  end

  test "no board is consulted on the dashboard" do
    # The wallet shows the rank; the dashboard shows the piles. A standing is
    # a query per row against a table that is still being written to, and
    # nothing on this page needs it.
    s = survey(tokenisation_enabled: true, leaderboard_enabled: true,
               token_types: [ { "id" => "gold", "name" => "Gold", "icon" => "🪙" } ])
    sign_in_with([ answered(s, tokens: { "gold" => 10 }, key: "device-1") ])

    boards = []
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      sql = payload[:sql].to_s
      boards << sql if sql.match?(/leaderboard_standings|player_aliases/i)
    end
    get you_path
    ActiveSupport::Notifications.unsubscribe(sub)

    assert_response :success
    assert_select "#vertos .you-pile", text: /🪙\s*10\s*Gold/
    assert_select ".you-standing", 0
    assert_empty boards, "the dashboard queried a board: #{boards.first}"
  end

  test "the dashboard is never written to a shared browser's disk cache" do
    sign_in_with([ answered(survey) ])

    get you_path
    assert_equal "no-store", response.headers["Cache-Control"]
  end
end
