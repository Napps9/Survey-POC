require "application_system_test_case"

# The editor half of the import-imagery fix, which is the half no request test
# can reach: FinishVertoSetupJob writes pictures into the deck while the creator
# is already looking at it, and until this existed the editor neither showed
# them nor knew they had arrived — so the next autosave, rebuilt from a DOM with
# no pictures in it, wrote that emptiness straight back over them.
class SetupStatusSystemTest < ApplicationSystemTestCase
  def setup
    super
    @user = User.create!(name: "U", email_address: "sss-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "sss-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")

    # An imported deck as it looks at the moment of the redirect: cids stamped,
    # not one picture in it, setup still pending.
    @survey = @org.surveys.create!(
      title: "Imported", theme: "Grassroots football", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      setup_pending_since: Time.current,
      cards: [
        { "type" => "multiple_choice", "cid" => "q0", "text" => "Which club?",   "options" => %w[Home Away] },
        { "type" => "multiple_choice", "cid" => "q1", "text" => "How often?",    "options" => %w[Weekly Rarely] }
      ]
    )
    sign_in_as(@user)
  end

  # What the job does, from outside the browser — the same write
  # AssetPopulator#populate_merged! makes.
  def job_writes_imagery!
    @survey.update!(cards: @survey.cards.map { |c|
      c.merge("image" => "/assets/verto-library/#{c['cid']}.jpg", "subject" => "a pitch")
    })
  end

  test "imagery the job writes appears without a reload, and survives the next save" do
    visit "/surveys/#{@survey.id}"
    assert_selector "[data-survey-editor-target='card']", minimum: 2, wait: 5
    assert_equal "", page.find("[data-card-cid='q0']")[:"data-card-image"].to_s,
                 "the editor opens with no imagery — that is the whole problem"

    job_writes_imagery!

    # The poll paints it in. The DATASET is what matters, not the pixels:
    # serialize() rebuilds the deck from these attributes and emits `image`
    # only when this one is non-empty.
    assert_selector "[data-card-cid='q0'][data-card-image='/assets/verto-library/q0.jpg']", wait: 10
    assert_selector "[data-card-cid='q1'][data-card-image='/assets/verto-library/q1.jpg']"
    assert_equal "a pitch", page.find("[data-card-cid='q0']")[:"data-card-subject"],
                 "subject renders nowhere, which is exactly why it gets dropped — serialize() emits it"

    # Now the edit that used to destroy everything. Caret to the END of the
    # contenteditable first — a bare click lands it wherever the pointer was.
    title = find("[data-card-cid='q0'] .q-title")
    title.click
    page.execute_script(<<~JS, title)
      const el = arguments[0]
      el.focus()
      const r = document.createRange(); r.selectNodeContents(el); r.collapse(false)
      const s = window.getSelection(); s.removeAllRanges(); s.addRange(r)
    JS
    title.send_keys(" now?")

    deadline = Time.current + 10
    loop do
      break if @survey.reload.cards.first["text"].to_s.include?("now?")
      raise "the edit never saved" if Time.current > deadline
      sleep 0.2
    end

    card = @survey.reload.cards.first
    assert_match(/now\?/, card["text"], "the creator's edit lands")
    assert_equal "/assets/verto-library/q0.jpg", card["image"],
                 "…and the imagery it used to wipe is still there"
  end
end
