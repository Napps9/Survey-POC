require "test_helper"

# The two pages an account exists for: what you said next to what everyone
# said, and what you collected.
#
# Three properties carry this file, and all three are about what these pages
# must NOT do. They must not become a way around small-cell suppression; they
# must not overrule the creator's own comparison switch; and they must not
# merge two Vertos' token piles just because both creators happened to name a
# token "gold".
class YouCompareWalletTest < ActionDispatch::IntegrationTest
  CARDS = [
    { "type" => "welcome_card", "cid" => "w", "text" => "Hello" },
    { "type" => "multiple_choice", "cid" => "q", "text" => "What would you want first?",
      "options" => [ "Wider pavements", "More trees", "Somewhere to sit" ] }
  ].freeze

  def org(name = "Haverley") = Organisation.create!(name: name, slug: "yc-#{SecureRandom.hex(3)}")

  def survey(owner: nil, cards: CARDS, **attrs)
    (owner || org).surveys.create!(
      title: "T", theme: "Car-free High Street", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ], cards: cards.map(&:dup),
      show_results_comparison: true,
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current, **attrs)
  end

  def answered(s, value: "More trees", tokens: nil, key: nil)
    s.responses.create!(session_token: SecureRandom.uuid, status: "completed", answered: true,
                        completed_at: 1.day.ago,
                        answers: { "1" => { "type" => "multiple_choice", "value" => value } },
                        token_totals: tokens || {},
                        player_key_digest: key ? s.player_key_digest(key) : nil)
  end

  # Enough other people to clear MIN_REGION_SAMPLE_SIZE.
  def crowd(s, n = 6, value: "Wider pavements")
    n.times { answered(s, value: value) }
  end

  def sign_in_with(claims)
    pl = Player.for_email("yc-#{SecureRandom.hex(4)}@test.com")
    _link, raw = PlayerSignInLink.mint!(
      player: pl, claim_payload: claims.map { |r| { "response_id" => r.id, "source" => "signup" } })
    post player_sign_in_path(raw)
    pl
  end

  # ── The comparison ────────────────────────────────────────────────────────

  test "it shows your answer against everyone else's" do
    s = survey
    crowd(s, 6, value: "Wider pavements")
    mine = answered(s, value: "More trees")
    sign_in_with([ mine ])

    get you_verto_path(s)

    assert_response :success
    assert_select ".you-q-prompt", text: "What would you want first?"
    assert_select ".you-q-mine", text: /More trees/
    # Their own bar is marked, and only theirs.
    assert_select ".you-bar-row.is-mine", 1
    assert_select ".you-bar-row.is-mine .you-bar-label", text: "More trees"
    # 6 of 7 chose the other option.
    assert_select ".you-bar-row", 3
    assert_match "86%", response.body
  end

  test "under the small-cell floor it refuses the comparison, exactly as the player does" do
    # Four responders total: on a Verto this small the "comparison" IS the
    # other respondents' answers, attributable by anyone who knows who was
    # asked. An account must not be a way around that.
    s = survey
    crowd(s, 3)
    mine = answered(s, value: "More trees")
    assert_operator s.responses.where(answered: true).count, :<, Response::MIN_REGION_SAMPLE_SIZE
    sign_in_with([ mine ])

    get you_verto_path(s)

    assert_response :success
    assert_select ".you-bar-row", 0
    assert_select ".you-sub", text: I18n.t("you.comparison_too_few")
  end

  test "the creator's comparison switch still decides, and the Verto is kept either way" do
    s = survey(show_results_comparison: false)
    crowd(s, 8)
    mine = answered(s, value: "More trees")
    sign_in_with([ mine ])

    get you_verto_path(s)

    assert_response :success
    assert_select ".you-bar-row", 0
    assert_select ".you-sub", text: I18n.t("you.comparison_off", org: s.organisation.name)
    assert_select "h1.you-h1", text: "Car-free High Street", count: 1
  end

  test "a question with no set options shows your answer without inventing a chart" do
    s = survey(cards: [ { "type" => "welcome_card", "cid" => "w", "text" => "Hi" },
                        { "type" => "open_ended", "cid" => "o", "text" => "Anything else?" } ])
    6.times do
      s.responses.create!(session_token: SecureRandom.uuid, status: "completed", answered: true,
                          answers: { "1" => { "type" => "open_ended", "value" => "Something" } })
    end
    mine = s.responses.create!(session_token: SecureRandom.uuid, status: "completed", answered: true,
                               answers: { "1" => { "type" => "open_ended", "value" => "Wider pavements please" } })
    sign_in_with([ mine ])

    get you_verto_path(s)

    assert_select ".you-q-mine", text: /Wider pavements please/
    assert_select ".you-bar-row", 0
  end

  # ── Whose Verto is it ─────────────────────────────────────────────────────

  test "a Verto this account has not kept is not found, whether or not it exists" do
    o = org
    mine   = survey(owner: o)
    theirs = survey(owner: o)
    my_run = answered(mine)
    answered(theirs)
    sign_in_with([ my_run ])

    get you_verto_path(theirs)
    assert_redirected_to you_path

    # And an id that is nothing at all reads identically.
    get you_verto_path(999_999)
    assert_redirected_to you_path
  end

  test "signed out, both pages send you to the page that explains what this is" do
    get you_wallet_path
    assert_redirected_to you_path

    get you_verto_path(1)
    assert_redirected_to you_path
  end

  # ── The wallet ────────────────────────────────────────────────────────────

  test "it totals across Vertos and keeps each Verto's piles apart" do
    o = org
    first  = survey(owner: o, tokenisation_enabled: true,
                    token_types: [ { "id" => "gold", "name" => "Ideas", "icon" => "🚲" } ])
    second = survey(owner: o, tokenisation_enabled: true,
                    token_types: [ { "id" => "gold", "name" => "Green", "icon" => "🌳" } ])
    a = answered(first,  tokens: { "gold" => 34 })
    b = answered(second, tokens: { "gold" => 88 })
    sign_in_with([ a, b ])

    get you_wallet_path

    assert_response :success
    assert_select ".you-total", text: "122"
    # Two rows, and the SAME token id means two different things — the piles
    # must not have merged. duplicate! copies token_types verbatim and
    # sanitize_token_types passes creator ids straight through, so this is the
    # ordinary case, not a contrived one.
    assert_select ".you-verto", 2
    assert_select ".you-pile", text: /🚲\s*34\s*Ideas/
    assert_select ".you-pile", text: /🌳\s*88\s*Green/
  end

  test "rows are ordered by when they were answered, not when they were claimed" do
    # A device key can attach a Verto from March to an account today, and one
    # sign-in claims everything at the same microsecond — so claimed_at is both
    # incoherent with the date these pages display and non-deterministic.
    o = org
    older = survey(owner: o, tokenisation_enabled: true,
                   token_types: [ { "id" => "leaf", "name" => "Old", "icon" => "🍂" } ])
    newer = survey(owner: o, tokenisation_enabled: true,
                   token_types: [ { "id" => "leaf", "name" => "New", "icon" => "🌱" } ])
    a = answered(older, tokens: { "leaf" => 1 })
    b = answered(newer, tokens: { "leaf" => 2 })
    a.update_column(:completed_at, 90.days.ago)
    b.update_column(:completed_at, 1.day.ago)
    sign_in_with([ a, b ])

    get you_wallet_path
    # Scoped to the list: the pill's hover breakdown draws the same component
    # for the same rows, in the same order, in the corner of this very page.
    assert_equal [ "🌱 2 New", "🍂 1 Old" ],
                 css_select(".you-list .you-pile").map { |e| e.text.split.join(" ") }

    get you_path
    assert_equal [ newer.id, older.id ].map { |id| you_verto_path(id) },
                 css_select("a.you-verto").map { |e| e["href"] }
  end

  test "a Verto that awards nothing is not a row in the wallet" do
    o = org
    with    = survey(owner: o, tokenisation_enabled: true,
                     token_types: [ { "id" => "leaf", "name" => "Leaves", "icon" => "🍃" } ])
    without = survey(owner: o)
    a = answered(with, tokens: { "leaf" => 5 })
    b = answered(without)
    sign_in_with([ a, b ])

    get you_wallet_path

    assert_select ".you-verto", 1
    assert_select ".you-total", text: "5"
  end

  test "with nothing collected the wallet says so rather than showing a zero" do
    s = survey
    sign_in_with([ answered(s) ])

    get you_wallet_path

    assert_response :success
    assert_select ".you-total", 0
    assert_select ".you-sub", text: I18n.t("you.wallet_empty")
  end

  test "the wallet says why the piles cannot be compared" do
    # Not a disclaimer — anyone reading this will ask, and answering it in the
    # interface is cheaper than answering it in support.
    s = survey(tokenisation_enabled: true,
               token_types: [ { "id" => "leaf", "name" => "Leaves", "icon" => "🍃" } ])
    sign_in_with([ answered(s, tokens: { "leaf" => 3 }) ])

    get you_wallet_path

    assert_select ".you-foot-note", text: I18n.t("you.wallet_note")
  end

  test "there is no rank that spans Vertos" do
    o = org
    a = survey(owner: o, tokenisation_enabled: true, leaderboard_enabled: true,
               token_types: [ { "id" => "leaf", "name" => "Leaves", "icon" => "🍃" } ])
    b = survey(owner: o, tokenisation_enabled: true, leaderboard_enabled: true,
               token_types: [ { "id" => "leaf", "name" => "Leaves", "icon" => "🍃" } ])
    ra = answered(a, tokens: { "leaf" => 10 }, key: "device-1")
    rb = answered(b, tokens: { "leaf" => 90 }, key: "device-1")
    sign_in_with([ ra, rb ])

    get you_wallet_path

    # Each Verto's own board, each with its own anonymous name — the boards
    # were never joined and this must not join them.
    names = css_select(".you-standing").map(&:text)
    assert_equal 2, names.size
    assert_select ".you-total", text: "100"
    # And nothing anywhere claims a position across the two.
    assert_select ".you-total-sub", text: /Across 2 Vertos/
  end

  test "the account's own totals are a snapshot, not a live recomputation" do
    # apply_token_totals recomputes from the CURRENT cards on every save, so a
    # creator re-tuning awards next month changes what future respondents earn.
    # It must not change what this person collected in May.
    s = survey(tokenisation_enabled: true,
               token_types: [ { "id" => "leaf", "name" => "Leaves", "icon" => "🍃" } ])
    mine = answered(s, tokens: { "leaf" => 40 })
    sign_in_with([ mine ])

    s.update!(cards: CARDS.map(&:dup), token_types: [ { "id" => "leaf", "name" => "Leaves", "icon" => "🍃" } ])

    get you_wallet_path
    assert_select ".you-total", text: "40"
  end

  # ── Getting between them ──────────────────────────────────────────────────

  test "the tabs mark where you are" do
    s = survey
    sign_in_with([ answered(s) ])

    get you_path
    assert_select ".you-tab[aria-current=page]", text: I18n.t("you.tab_vertos")

    get you_next_path
    assert_select ".you-tab[aria-current=page]", text: I18n.t("you.tab_next")
  end

  # ── Why a Verto can't be compared ─────────────────────────────────────────
  #
  # Two gates gate the comparison, and from the outside a respondent cannot
  # tell them apart — or tell either from "this is broken". The list says which
  # one, on the row, so nobody opens a Verto to find out there is nothing in it.

  test "a Verto whose results the creator hasn't opened says so on the list" do
    s = survey(show_results_comparison: false)
    crowd(s, 8)
    sign_in_with([ answered(s) ])

    get you_path

    assert_select ".you-verto-note",
                  text: I18n.t("you.compare_closed", org: s.organisation.name)
  end

  test "a Verto below the floor names the floor and the count, not 'soon'" do
    # 2 of 5 tells a respondent whether to come back tomorrow or never.
    # "Not enough yet" tells them nothing and sends them to support.
    s = survey
    crowd(s, 1)
    sign_in_with([ answered(s) ])

    assert_operator s.responses.where(answered: true).count, :<,
                    Response::MIN_REGION_SAMPLE_SIZE
    get you_path

    assert_select ".you-verto-note",
                  text: I18n.t("you.compare_pending",
                               needed: Response::MIN_REGION_SAMPLE_SIZE, have: 2)
  end

  test "a Verto that can be compared is not labelled at all" do
    # Opening it is the point of the row; a badge saying so is noise.
    s = survey
    crowd(s, 8)
    sign_in_with([ answered(s) ])

    get you_path

    assert_select ".you-verto", 1
    assert_select ".you-verto-note", 0
  end

  test "the Verto's own page says when the comparison opens, not just that it hasn't" do
    s = survey
    crowd(s, 2)
    sign_in_with([ answered(s) ])

    get you_verto_path(s)

    assert_select ".you-sub", text: I18n.t("you.comparison_too_few")
    assert_select ".you-fine",
                  text: I18n.t("you.compare_pending",
                               needed: Response::MIN_REGION_SAMPLE_SIZE, have: 3)
  end

  test "the reasons cost one query however many Vertos are listed" do
    # This runs on the page that lists every Verto an account holds, so a
    # per-row count is a per-row query. Counted rather than asserted by eye:
    # the batching is the whole reason the line can live on the list.
    o = org
    claims = 4.times.map do
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

    assert_select ".you-verto-note", 4
    assert_equal 1, counts,
                 "expected one grouped COUNT over responses for the whole list, got #{counts}"
  end

  # ── The wallet pill ───────────────────────────────────────────────────────
  #
  # The wallet stopped being a tab and became a pill in the top corner, so the
  # tests that used to say "the tab is there and marks the page" say it about
  # the pill — and about the thing a tab could never do, which is carry the
  # number that makes it worth pressing.

  def pilled(owner, name, icon, amount, id: "gold")
    s = survey(owner: owner, tokenisation_enabled: true,
               token_types: [ { "id" => id, "name" => name, "icon" => icon } ])
    [ s, answered(s, tokens: { id => amount }) ]
  end

  test "the pill carries the total on every page of the account, and marks the wallet" do
    o = org
    first,  a = pilled(o, "Ideas", "🚲", 34)
    _second, b = pilled(o, "Green", "🌳", 88)
    sign_in_with([ a, b ])

    [ you_path, you_next_path, you_verto_path(first) ].each do |path|
      get path
      assert_select "a.you-purse-pill[href=?]", you_wallet_path, 1, "no wallet pill on #{path}"
      assert_select ".you-purse-total", text: "122"
      # Off the wallet, the pill is a way there and not a marker of where you
      # are. Two aria-currents on one page is a page that cannot say.
      assert_select ".you-purse-pill[aria-current]", 0, "#{path} marked the pill as the current page"
    end

    get you_wallet_path
    assert_select ".you-purse-pill[aria-current=page]", 1
    # And the one number is one computation: the pill and the page it links to
    # cannot disagree about what the account holds.
    assert_select ".you-purse-total", text: "122"
    assert_select ".you-total", text: "122"
  end

  test "the pill's breakdown keeps each Verto's tokens apart, and offers the rest" do
    o = org
    _first,  a = pilled(o, "Ideas", "🚲", 34)
    _second, b = pilled(o, "Green", "🌳", 88)
    sign_in_with([ a, b ])

    get you_path

    # Two Vertos, both using the id "gold" for two different things — the
    # breakdown names each Verto and counts its own tokens under it.
    assert_select ".you-purse-row", 2
    assert_select ".you-purse-row .you-pile", text: /🚲\s*34\s*Ideas/
    assert_select ".you-purse-row .you-pile", text: /🌳\s*88\s*Green/
    assert_select ".you-purse-verto", text: "Car-free High Street", count: 2
    assert_select "a.you-purse-all[href=?]", you_wallet_path, text: /#{I18n.t("you.wallet_see_all")}/
  end

  test "the breakdown is a peek at five, not a second wallet" do
    o = org
    claims = 7.times.map { |i| pilled(o, "Leaves", "🍃", i + 1, id: "leaf-#{i}").last }
    sign_in_with(claims)

    get you_path
    assert_select ".you-purse-row", YouController::PURSE_PREVIEW
    # The rest are not lost, they are behind the CTA.
    assert_select "a.you-purse-all[href=?]", you_wallet_path

    get you_wallet_path
    assert_select ".you-list .you-verto", 7
    assert_select ".you-total", text: "28"
  end

  test "the breakdown is a peek for a pointer, never a second reading of the page" do
    # Every row in it is on the wallet the pill points at, and the pill's own
    # label already carries the total. Exposing it would put the same five
    # Vertos into the reading order of every page of the account.
    o = org
    _s, a = pilled(o, "Ideas", "🚲", 34)
    sign_in_with([ a ])

    get you_path

    assert_select ".you-purse-popover[aria-hidden=true][hidden]", 1
    assert_select ".you-purse-pill[aria-label=?]",
                  I18n.t("you.wallet_pill", total: "34")
    # Nothing inside it is reachable by tab — focusable content inside
    # aria-hidden is a trap rather than a shortcut.
    assert_select ".you-purse-popover a[tabindex=?]", "-1", 1
    assert_select ".you-purse-popover a:not([tabindex])", 0
  end

  test "with nothing collected there is no pill, because there is nothing to press it for" do
    # The wallet already made this choice: it says "no points yet" rather than
    # showing a zero. A pill showing 0 would be an affordance promising that
    # sentence.
    s = survey
    sign_in_with([ answered(s) ])

    get you_path
    assert_select ".you-purse", 0

    # The page itself is still reachable, and still says so.
    get you_wallet_path
    assert_response :success
    assert_select ".you-sub", text: I18n.t("you.wallet_empty")
    assert_select ".you-purse", 0
  end

  test "signed out there is no pill at all" do
    get you_path

    assert_response :success
    assert_select ".you-purse", 0
  end

  test "every Verto in the list opens its own page" do
    s = survey
    sign_in_with([ answered(s) ])

    get you_path
    assert_select "a.you-verto[href=?]", you_verto_path(s)
  end

  test "the account renders in en-US, not only in en" do
    # The whole suite runs in `en`, so a key that is broken only in the
    # GENERATED en-US.yml is invisible to every other test here. That is not
    # hypothetical: wallet_across shipped with %{organisations} in it, the
    # generator respelled the interpolation NAME to %{organizations}, and the
    # page raised MissingInterpolationArgument for every en-US visitor while
    # `en` stayed green. EnglishSpellings now protects placeholders and
    # en_us_locale_test guards the file; this renders the pages under the
    # variant so a future one cannot slip through either.
    s = survey(tokenisation_enabled: true,
               token_types: [ { "id" => "leaf", "name" => "Leaves", "icon" => "🍃" } ])
    crowd(s, 6)
    sign_in_with([ answered(s, tokens: { "leaf" => 12 }) ])

    get you_wallet_path(locale: "en-US")
    assert_response :success
    assert_select ".you-total", text: "12"

    get you_verto_path(s, locale: "en-US")
    assert_response :success
    assert_select ".you-q-prompt"
  end

  test "these pages are never written to a shared browser's disk cache" do
    s = survey
    sign_in_with([ answered(s) ])

    get you_wallet_path
    assert_equal "no-store", response.headers["Cache-Control"]

    get you_verto_path(s)
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_match(/noindex/, response.headers["X-Robots-Tag"].to_s)
  end
end
