require "test_helper"

# A second logo, for light surfaces.
#
# Everything the platform draws is dark chrome — the player's masthead, the
# thank-you card, the editor, this settings page — except one thing, and it is
# the first thing a respondent ever sees: the welcome card's logo sits on the
# WHITE answer panel. An account whose only mark is a white wordmark (the
# normal case, precisely because the rest of the platform is dark) had it
# disappear there. "Need the ability to upload a version of the logo that's
# black/coloured, as we've used a white version for desktop."
#
# The attachment is named for the SURFACE it goes on rather than for its own
# colour, because "logo_light" reads both ways and the wrong reading picks the
# invisible one — a light logo is what you use on a DARK background.
class BrandLogoOnLightTest < ActionDispatch::IntegrationTest
  PNG = "\x89PNG\r\n\x1a\n".freeze

  def setup
    @org   = Organisation.create!(name: "Econ", slug: "light-#{SecureRandom.hex(2)}")
    @admin = User.create!(name: "A", email_address: "a-#{SecureRandom.hex(2)}@t.com",
                          password: "verylongpassword")
    @org.memberships.create!(user: @admin, role: "admin")
  end

  def login
    post session_path, params: { email_address: @admin.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def attach(field, name)
    @org.public_send(field).attach(io: StringIO.new(PNG), filename: name, content_type: "image/png")
  end

  def upload(name = "light.png", type = "image/png", body = PNG)
    Rack::Test::UploadedFile.new(StringIO.new(body), type, original_filename: name)
  end

  # ── The resolver, which is where the whole feature lives ──

  test "a light surface prefers the alternate when there is one" do
    attach(:logo, "dark-surface.png")
    attach(:logo_on_light, "light-surface.png")

    helper = ApplicationController.helpers
    assert_equal "light-surface.png", helper.brand_logo_for(@org.reload, :light).filename.to_s
    assert_equal "dark-surface.png",  helper.brand_logo_for(@org.reload, :dark).filename.to_s
  end

  # The fallback is the point: an account that uploads one logo must behave
  # exactly as it did before this existed. A missing alternate is a
  # worse-looking logo, never no logo.
  test "a light surface falls back to the only logo there is" do
    attach(:logo, "only.png")
    helper = ApplicationController.helpers

    assert_equal "only.png", helper.brand_logo_for(@org.reload, :light).filename.to_s
    assert_equal "only.png", helper.brand_logo_for(@org.reload, :dark).filename.to_s
  end

  test "an account with no logo at all still gets nothing, on either surface" do
    helper = ApplicationController.helpers
    assert_nil helper.brand_logo_for(@org, :light)
    assert_nil helper.brand_logo_for(@org, :dark)
    assert_nil helper.brand_logo_for(nil, :light)
  end

  # ── The upload path ──

  test "an admin uploads and removes the light-background logo" do
    login
    assert_difference -> { @org.reload.logo_on_light.attached? ? 1 : 0 }, 1 do
      patch organisation_path(@org), params: { organisation: { logo_on_light: upload } }
    end
    assert @org.reload.logo_on_light.attached?
    # The main logo is untouched by a second-slot upload.
    assert_not @org.logo.attached?

    patch organisation_path(@org), params: { organisation: { remove_logo_on_light: "1" } }
    assert_not @org.reload.logo_on_light.attached?
  end

  test "removing one logo leaves the other alone" do
    attach(:logo, "main.png")
    attach(:logo_on_light, "light.png")
    login

    patch organisation_path(@org), params: { organisation: { remove_logo_on_light: "1" } }
    assert @org.reload.logo.attached?,        "removing the light logo took the main one with it"
    assert_not @org.logo_on_light.attached?

    attach(:logo_on_light, "light-again.png")
    patch organisation_path(@org), params: { organisation: { remove_logo: "1" } }
    assert_not @org.reload.logo.attached?
    assert @org.logo_on_light.attached?,      "removing the main logo took the light one with it"
  end

  # An unsanitised SVG served same-origin is stored XSS. The first slot has
  # always scrubbed; a second slot that skipped it would be a second door into
  # the same hole, which is why the controller loops over both rather than
  # repeating the block for one.
  test "an SVG uploaded to the light slot is sanitised like any other" do
    login
    hostile = <<~SVG
      <svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script><rect width="4" height="4"/></svg>
    SVG
    patch organisation_path(@org),
          params: { organisation: { logo_on_light: upload("x.svg", "image/svg+xml", hostile) } }

    assert @org.reload.logo_on_light.attached?, "the SVG was rejected outright rather than cleaned"
    stored = @org.logo_on_light.download
    assert_not_includes stored, "<script", "a script tag reached storage on the light-logo path"
  end

  test "the settings page offers the second slot to an admin" do
    login
    get organisation_memberships_path(@org)
    assert_response :success
    assert_select "input[name='organisation[logo_on_light]']", 1
  end

  # The resolver being right is only half of it — the welcome card has to
  # actually ASK for the light surface. It is the single call site that does;
  # every other logo on the platform sits on dark chrome, including the
  # thank-you card (#1C2034), which is why this is one `on:` and not a sweep.
  test "the welcome card draws the light logo while the masthead keeps the dark one" do
    attach(:logo, "for-dark.png")
    attach(:logo_on_light, "for-light.png")
    @org.reload

    survey = @org.surveys.create!(title: "S", theme: "T", audience_age: "all", key_insight: "k",
                                  default_locale: "en", locales: [ "en" ],
                                  cards: [ { "type" => "welcome_card", "title" => "Hi" } ])
    survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)

    get "/play/#{survey.publish_token}"
    assert_response :success

    # The proxy path carries the filename, so the two are told apart by name
    # without having to build a signed id in the test.
    dark, light = "for-dark.png", "for-light.png"

    assert_includes response.body, light,
                    "the welcome card is not drawing the light-surface logo, so a white wordmark " \
                    "is still invisible on the white answer panel"
    assert_includes response.body, dark,
                    "the masthead should still use the main logo — it sits on the brand backdrop, " \
                    "not on white"
  end

  # A light-only account is a real state: someone can upload the alternate
  # first, or remove the main logo afterwards. The welcome card's `if` used to
  # test `organisation.logo.attached?` directly, which would have rendered an
  # empty slot for exactly that account.
  test "an account with only a light logo still gets one on the welcome card" do
    attach(:logo_on_light, "light-only.png")
    @org.reload

    survey = @org.surveys.create!(title: "S2", theme: "T", audience_age: "all", key_insight: "k",
                                  default_locale: "en", locales: [ "en" ],
                                  cards: [ { "type" => "welcome_card", "title" => "Hi" } ])
    survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)

    get "/play/#{survey.publish_token}"
    assert_response :success
    assert_includes response.body, "light-only.png",
                    "the welcome card rendered no logo for an account that has one"
  end

  # ── The second slot inherits the first slot's manners ──
  #
  # It shipped without them. The size and content-type guard named `logo`
  # directly, so a 3 MB PDF attached to the light slot and the record validated
  # clean — a second upload with none of the first one's checks. The scrubber in
  # the controller had already been written as a loop over both, for the same
  # class of reason, which makes the omission here the odd one out rather than a
  # deliberate difference.
  #
  # The fields are LISTED HERE, not read from Organisation::LOGO_ATTACHMENTS.
  # Driving the loop off the constant looked tidier and was a test that could
  # not fail: dropping a field from the constant is exactly the regression, and
  # it would also have deleted the test for it — the suite went from 15 runs to
  # 12 and reported one failure instead of three. The constant is asserted
  # separately below so a new slot still cannot arrive unguarded.
  %i[logo logo_on_light].each do |field|
    test "#{field} refuses a file that is not a supported image" do
      login
      patch organisation_path(@org),
            params: { organisation: { field => upload("brochure.pdf", "application/pdf", "%PDF-1.4") } },
            headers: { "Accept" => "application/json" }

      assert_response :unprocessable_entity
      assert_match(/PNG|image/i, JSON.parse(response.body)["error"].to_s,
                   "#{field} accepted a PDF, or refused it without saying why")
      refute @org.reload.public_send(field).attached?,
             "#{field} stored a PDF"
    end

    test "#{field} refuses a file over the size cap" do
      login
      oversized = upload("huge.png", "image/png", "a" * (Organisation::LOGO_MAX_BYTES + 1))
      patch organisation_path(@org),
            params: { organisation: { field => oversized } },
            headers: { "Accept" => "application/json" }

      assert_response :unprocessable_entity
      assert_match(/MB/, JSON.parse(response.body)["error"].to_s,
                   "#{field} accepted an oversized file, or refused it without a readable reason")
      refute @org.reload.public_send(field).attached?, "#{field} stored an oversized file"
    end
  end

  test "every attached logo slot is covered by the guard" do
    # The other half of the pair above: that loop pins the two slots that exist
    # today, and this pins that no THIRD one appears without them. Read off the
    # model's own attachment reflection rather than a list someone has to
    # remember to update.
    attached = Organisation.reflect_on_all_attachments.map(&:name)
                           .select { |n| n.to_s.include?("logo") }.sort

    assert_equal attached, Organisation::LOGO_ATTACHMENTS.sort,
                 "these logo attachments are not in LOGO_ATTACHMENTS, so nothing checks " \
                 "their type or size: #{(attached - Organisation::LOGO_ATTACHMENTS).inspect}"
  end

  test "the guard names the field that was wrong, not just 'logo'" do
    # An account uploading a bad light logo should not be told its main logo is
    # the problem — there are two slots on that page and only one of them is.
    @org.logo_on_light.attach(io: StringIO.new("%PDF-1.4"), filename: "b.pdf",
                              content_type: "application/pdf")

    refute @org.valid?
    assert @org.errors[:logo_on_light].any?,
           "the error was filed against the wrong attachment, so the settings page cannot " \
           "point at the field the creator actually needs to fix"
    assert_empty @org.errors[:logo],
                 "a bad light logo raised an error against the main logo, which is attached " \
                 "and fine"
  end
end
