Rails.application.routes.draw do
  # Public player (no auth)
  get  "play/:token",        to: "player#show",   as: :play_survey
  post "play/:token/progress", to: "player#progress", as: :progress_survey
  post "play/:token/submit", to: "player#submit", as: :submit_survey
  post "play/:token/grade", to: "player#grade", as: :grade_survey
  post "play/:token/consent", to: "player#consent", as: :consent_survey
  get  "play/:token/quiz_state", to: "player#quiz_state", as: :quiz_state_survey
  get  "play/:token/scores", to: "player#scores", as: :player_scores
  get  "play/:token/results", to: "player#results", as: :player_results
  get  "play/:token/regions", to: "player#regions", as: :player_regions
  get  "play/:token/leaderboard", to: "player#leaderboard", as: :player_leaderboard
  get  "play/:token/location_search", to: "player#location_search", as: :player_location_search
  # Per-Verto PWA install manifest — see PlayerController#manifest.
  get  "play/:token/manifest", to: "player#manifest", as: :play_manifest

  # Test Mode: shareable while still editable, records nothing. Deliberately
  # OUTSIDE /play/ — the service worker's scope is /play/ only and it serves
  # player HTML stale-while-revalidate, which would pin a mutable test link
  # one edit behind forever (see app/javascript/sw_register.js).
  get "test/:token", to: "player#test_show", as: :test_survey

  # Shareable results/report links (no auth) — a public, read-only view of a
  # Verto's aggregated results, distinct from /play (that's the respondent
  # experience) and outside it on purpose: /play/ is the service worker's
  # whole scope, and a results page has no business being cached offline.
  # See SharedResultsController for the PII/spend boundaries.
  get  "results/:token",                             to: "shared_results#show",          as: :shared_results
  get  "results/:token/report",                       to: "shared_results#report",        as: :shared_results_report
  post "results/:token/report/renders",                to: "shared_results#create_render", as: :shared_results_renders
  get  "results/:token/report/renders/:id",            to: "shared_results#render_status", as: :shared_results_render
  get  "results/:token/report/renders/:id/download",   to: "shared_results#render_download", as: :download_shared_results_render

  # Auth
  resource  :session,       only: [ :new, :create, :destroy ]
  resources :passwords,     param: :token, only: [ :new, :create, :edit, :update ]
  resources :registrations, only: [ :new, :create ]
  # Email verification (P0-8). #show is the link in the email (unauthenticated —
  # people open these on a device that isn't signed in); #create is the resend.
  get  "email-confirmations/:token", to: "email_confirmations#show",   as: :email_confirmation
  post "email-confirmations",        to: "email_confirmations#create", as: :email_confirmations

  # Social sign-in (OmniAuth). /auth/:provider itself is middleware.
  get "auth/:provider/callback", to: "oauth_sessions#create", as: :oauth_callback
  get "auth/failure",            to: "oauth_sessions#failure"

  # Google Sheets export OAuth (callback is a GET — Google redirects via browser)
  get "google/connect",  to: "google_auth#connect",  as: :google_connect
  get "google/callback", to: "google_auth#callback", as: :google_callback

  # Org switcher
  post "switch_organisation", to: "organisations#switch", as: :switch_organisation

  # UI language switcher (works on public pages too)
  post "locale", to: "locales#update", as: :locale

  # Legal pages (public, no auth) — linked from the cookie-consent banner and
  # the footer on every unauthenticated page.
  get "privacy",       to: "legal#privacy",       as: :privacy
  get "terms",         to: "legal#terms",         as: :terms
  get "cookie-policy", to: "legal#cookie_policy", as: :cookie_policy

  # Org management (admin only)
  resources :organisations, only: [ :edit, :update ] do
    resources :memberships, only: [ :index, :destroy ]
    resources :invites,     only: [ :new, :create ]
    # The account's own brand-asset library (uploaded images reusable across
    # its Vertos from the editor media picker).
    resources :assets, only: [ :create, :destroy ], controller: "organisation_assets"
  end

  # Public invite acceptance (no auth)
  get  "invites/:token",        to: "invites#show",   as: :invite
  post "invites/:token/accept", to: "invites#accept", as: :accept_invite

  # Health + PWA
  get "up"             => "health#show", as: :rails_health_check
  get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker
  get "manifest"       => "rails/pwa#manifest",       as: :pwa_manifest

  # Internal BI — read-only SQL dashboards over the whole app DB, for VertoNow
  # staff only. The constraint resolves the signed-in user from the session
  # cookie and checks the BLAZER_STAFF_EMAILS allowlist (deny-by-default), so a
  # non-staff or anonymous request never matches and 404s — the engine isn't
  # even reached. See app/lib/blazer_access.rb.
  constraints(->(request) { BlazerAccess.staff_request?(request) }) do
    mount Blazer::Engine, at: "/blazer"
  end

  # App
  root "surveys#index"
  get  "templates",                   to: "templates#index",  as: :survey_templates
  post "templates/:id",               to: "templates#create", as: :survey_template
  get  "surveys/new",                 to: "surveys#new",     as: :new_survey
  post "surveys/generate",            to: "surveys#generate", as: :generate_survey
  resources :verto_builds, only: [ :show ]
  get "verto_builds/:id/import", to: "surveys#resume_import", as: :resume_import
  post "surveys/import_pdf",          to: "surveys#import_pdf", as: :import_pdf_survey
  post "surveys/import_google_form",  to: "surveys#import_google_form", as: :import_google_form_survey
  post "surveys/import_manual",       to: "surveys#import_manual", as: :import_manual_survey
  post "surveys/create_blank",        to: "surveys#create_blank", as: :create_blank_survey
  post "surveys/:id/moderate_image",  to: "surveys#moderate_image", as: :moderate_image_survey
  # Appeal flow for a rejected upload — file one, and list this survey's
  # already-approved ones for the picker strip. See ImageAppealsController.
  post "surveys/:id/image_appeal",    to: "image_appeals#create",  as: :image_appeal_survey
  get  "surveys/:id/image_appeals",   to: "image_appeals#index",   as: :image_appeals_survey
  post "surveys/finalize_import",     to: "surveys#finalize_import", as: :finalize_import_survey
  post "surveys/:id/publish",         to: "surveys#publish",  as: :publish_survey
  post "surveys/:id/unpublish",       to: "surveys#unpublish", as: :unpublish_survey
  post   "surveys/:id/test_link",     to: "surveys#enable_test_link",  as: :test_link_survey
  delete "surveys/:id/test_link",     to: "surveys#disable_test_link"
  post   "surveys/:id/test_mode",     to: "surveys#convert_to_test_mode", as: :test_mode_survey
  # The results top bar's Share-results popover: mint/pause-resume/reset/
  # revoke the one results_share_token, same shape as test_link above.
  post   "surveys/:id/results_share", to: "results_shares#create",  as: :results_share_survey
  patch  "surveys/:id/results_share", to: "results_shares#update"
  delete "surveys/:id/results_share", to: "results_shares#destroy"
  # Repeat participation: start the next wave (closes whatever's open),
  # rename one.
  post  "surveys/:survey_id/waves",     to: "survey_waves#create", as: :survey_waves
  patch "surveys/:survey_id/waves/:id", to: "survey_waves#update", as: :survey_wave
  post "surveys/:id/duplicate",       to: "surveys#duplicate", as: :duplicate_survey
  # The Share modal, fetched into a Turbo Frame over the dashboard. A GET that
  # renders the panel; the nested link routes below mutate and redirect back to
  # it, so the frame re-renders itself with no JSON round-trip to hand-write.
  get  "surveys/:id/share",           to: "survey_links#show", as: :share_survey
  get  "surveys/:id/preview",         to: "surveys#preview",  as: :preview_survey
  get  "surveys/:id/qr",              to: "surveys#qr",       as: :qr_survey
  post "surveys/:id/card_image",      to: "surveys#card_image", as: :card_image_survey
  post "surveys/:id/card_lottie",     to: "surveys#card_lottie", as: :card_lottie_survey
  post "surveys/:id/settings",        to: "surveys#update_settings", as: :survey_settings
  # Separate from #settings because it can spend at Anthropic (re-tailoring the
  # Heritage card), and the settings endpoint must stay free to call.
  post "surveys/:id/audience_country", to: "surveys#update_audience_country", as: :audience_country_survey
  post "surveys/:id/shuffle_assets",  to: "surveys#shuffle_assets",  as: :shuffle_survey_assets
  get  "surveys/:id/results",         to: "surveys#results",  as: :survey_results
  get  "surveys/:id/results/compare", to: "surveys#results_compare", as: :survey_results_compare
  get  "surveys/:survey_id/results/export",       to: "results_exports#show",         as: :survey_results_export
  post "surveys/:survey_id/results/google_sheet", to: "google_sheets_exports#create", as: :survey_google_sheet
  get  "surveys/:survey_id/results/report",       to: "results_reports#show",         as: :survey_results_report
  # The PDF is built by a job, so asking for one and collecting it are separate steps.
  post "surveys/:survey_id/results/report/renders", to: "report_renders#create",     as: :survey_report_renders
  resources :report_renders, only: [ :show ] do
    member { get :download }
  end
  patch "surveys/:survey_id/results/report",      to: "results_reports#update"
  get  "surveys/:survey_id/results/report/stream", to: "results_report_streams#show",  as: :survey_results_report_stream
  post "surveys/:survey_id/results/google_drive", to: "google_drive_exports#create",  as: :survey_google_drive
  # GDPR data-subject rights for one respondent (P0-7). Admin-only — unlike every
  # other results route these answer for a named individual, not the aggregate.
  get    "surveys/:survey_id/respondent-data",        to: "respondent_data#show",    as: :survey_respondent_data
  get    "surveys/:survey_id/respondent-data/export", to: "respondent_data#export",  as: :survey_respondent_data_export
  delete "surveys/:survey_id/respondent-data",        to: "respondent_data#destroy"
  post "surveys/:id/generate_card",   to: "surveys#generate_card", as: :generate_survey_card
  post "surveys/:id/generate_flow",   to: "surveys#generate_flow", as: :generate_survey_flow
  # Flow generation runs as a job (GenerateFlowJob); the editor polls this and
  # splices the rendered cards when they land.
  resources :flow_generations, only: [ :show ]
  post "surveys/:id/render_card",     to: "surveys#render_card",   as: :render_survey_card
  post "surveys/:id/demographic_card", to: "surveys#add_demographic_card", as: :demographic_survey_card
  post "surveys/:id/restore_card",    to: "surveys#restore_card",  as: :restore_survey_card
  post "surveys/:id/optimise_card",   to: "surveys#optimise_card", as: :optimise_survey_card
  get  "surveys/:id/pexels",          to: "surveys#pexels_search", as: :pexels_search_survey
  get  "surveys/:id/results/summary", to: "survey_summaries#show",  as: :survey_results_summary
  get  "surveys/:id/results/summarize_texts", to: "survey_summaries#texts", as: :survey_results_summarize_texts
  post "surveys/:survey_id/chat",     to: "survey_chats#create",    as: :survey_chat
  # The creator's Ask Verto opt-in. Its own route rather than a settings field:
  # offering another organisation's researchers access to what your respondents
  # said is an admin decision with an audit trail, not an editing toggle.
  post   "surveys/:survey_id/corpus_entry", to: "corpus_entries#create",  as: :survey_corpus_entry
  delete "surveys/:survey_id/corpus_entry", to: "corpus_entries#destroy"
  delete "surveys/bulk_archive",        to: "surveys#bulk_archive",        as: :bulk_archive_surveys
  delete "surveys/bulk_destroy",        to: "surveys#bulk_destroy",        as: :bulk_destroy_surveys
  delete "surveys/:id/destroy_forever", to: "surveys#destroy_forever",     as: :destroy_forever_survey
  post   "surveys/:id/restore",          to: "surveys#restore",             as: :restore_survey
  resources :surveys, only: [ :show, :update, :destroy ] do
    # Named send links (SurveyLink). Nested because a link has no life of its
    # own — it's one of the addresses a particular Verto is reachable at.
    resources :links, only: [ :create, :update, :destroy ], controller: "survey_links"
  end

  # ── Ask Verto ──────────────────────────────────────────────────────────────
  # Cross-Verto question answering over the shared corpus. Open to any signed-in
  # account: what can be answered is decided by the corpus (CorpusEntry.citable),
  # not by who is asking, so there is one authorisation rule rather than two.
  get    "ask",                     to: "ask#show",             as: :ask
  post   "ask/threads",             to: "ask_threads#create",   as: :ask_threads
  delete "ask/threads/:id",         to: "ask_threads#destroy",  as: :ask_thread
  post   "ask/threads/:thread_id/messages", to: "ask_messages#create", as: :ask_thread_messages
  # The "Submit your Verto data" picker: a batch of opt-ins with question-set
  # granularity. Org-admin only (the controller enforces it) — offering
  # respondents' data outward is an admin decision, exactly as the per-survey
  # corpus_entry routes above.
  post   "ask/submissions",         to: "ask_submissions#create", as: :ask_submissions

  # The staff review queue. Gated by a routing CONSTRAINT rather than a filter,
  # exactly like /blazer above and for the same reason: a non-staff request gets
  # a 404, because the existence of an internal surface over other customers'
  # data is itself something customers have no reason to learn.
  constraints(->(request) { BlazerAccess.staff_request?(request) }) do
    get   "ask/review",     to: "corpus_reviews#index",  as: :corpus_reviews
    patch "ask/review/:id", to: "corpus_reviews#update", as: :corpus_review

    # The appeal queue for rejected uploads — see ImageReviewsController's
    # class comment for why this is staff-only rather than an org-admin call.
    get   "image_reviews",     to: "image_reviews#index",  as: :image_reviews
    patch "image_reviews/:id", to: "image_reviews#update", as: :image_review
  end

  # ── Comms ──────────────────────────────────────────────────────────────────
  # Email campaigns to the platform's users and imported lists. A Playverto
  # staff surface (CommsAccess: membership of the Playverto org), gated by a
  # routing CONSTRAINT exactly like /blazer and /ask/review above and for the
  # same reason: for anyone else these routes simply don't exist (404).
  constraints(->(request) { CommsAccess.allowed_request?(request) }) do
    get    "comms",                              to: "comms/campaigns#index",          as: :comms
    post   "comms/campaigns",                    to: "comms/campaigns#create",         as: :comms_campaigns
    post   "comms/newsletter",                   to: "comms/campaigns#generate_newsletter", as: :generate_comms_newsletter
    get    "comms/campaigns/:id/edit",           to: "comms/campaigns#edit",           as: :edit_comms_campaign
    patch  "comms/campaigns/:id",                to: "comms/campaigns#update",         as: :comms_campaign
    delete "comms/campaigns/:id",                to: "comms/campaigns#destroy"
    get    "comms/campaigns/:id/preview",        to: "comms/campaigns#preview",        as: :preview_comms_campaign
    post   "comms/campaigns/:id/image",          to: "comms/campaigns#image",          as: :image_comms_campaign
    post   "comms/campaigns/:id/moderate_image", to: "comms/campaigns#moderate_image", as: :moderate_image_comms_campaign
    get    "comms/campaigns/:id/pexels",         to: "comms/campaigns#pexels_search",  as: :pexels_comms_campaign
    post   "comms/campaigns/:id/audience_count", to: "comms/campaigns#audience_count", as: :audience_count_comms_campaign
    post   "comms/campaigns/:id/send_now",       to: "comms/campaigns#send_now",       as: :send_now_comms_campaign
    post   "comms/campaigns/:id/test_send",      to: "comms/campaigns#test_send",      as: :test_send_comms_campaign
    post   "comms/campaigns/:id/cancel_send",    to: "comms/campaigns#cancel_send",    as: :cancel_send_comms_campaign
    post   "comms/campaigns/:id/schedule",       to: "comms/campaigns#schedule",       as: :schedule_comms_campaign
    post   "comms/campaigns/:id/cancel_schedule", to: "comms/campaigns#cancel_schedule", as: :cancel_schedule_comms_campaign
    get    "comms/campaigns/:id/status",         to: "comms/campaigns#status",         as: :status_comms_campaign
    get    "comms/lists",                        to: "comms/lists#index",              as: :comms_lists
    post   "comms/lists",                        to: "comms/lists#create"
    get    "comms/lists/:id",                    to: "comms/lists#show",               as: :comms_list
    delete "comms/lists/:id",                    to: "comms/lists#destroy"
    get    "comms/automations",                  to: "comms/automations#index",        as: :comms_automations
    post   "comms/automations",                  to: "comms/automations#create"
    get    "comms/automations/:id/edit",         to: "comms/automations#edit",         as: :edit_comms_automation
    patch  "comms/automations/:id",              to: "comms/automations#update",       as: :comms_automation
    delete "comms/automations/:id",              to: "comms/automations#destroy"
    get    "comms/automations/:id/preview",      to: "comms/automations#preview",      as: :preview_comms_automation
    post   "comms/automations/:id/image",        to: "comms/automations#image",        as: :image_comms_automation
    post   "comms/automations/:id/moderate_image", to: "comms/automations#moderate_image", as: :moderate_image_comms_automation
    get    "comms/automations/:id/pexels",       to: "comms/automations#pexels_search", as: :pexels_comms_automation
    post   "comms/automations/:id/toggle",       to: "comms/automations#toggle",       as: :toggle_comms_automation
    post   "comms/automations/:id/test_send",    to: "comms/automations#test_send",    as: :test_send_comms_automation
    post   "comms/automations/:automation_id/steps",              to: "comms/automation_steps#create",  as: :comms_automation_steps
    get    "comms/automations/:automation_id/steps/:id/edit",     to: "comms/automation_steps#edit",    as: :edit_comms_automation_step
    patch  "comms/automations/:automation_id/steps/:id",          to: "comms/automation_steps#update",  as: :comms_automation_step
    delete "comms/automations/:automation_id/steps/:id",          to: "comms/automation_steps#destroy"
    get    "comms/automations/:automation_id/steps/:id/preview",  to: "comms/automation_steps#preview", as: :preview_comms_automation_step
  end

  # Public Comms endpoints — recipients are not platform users, so these sit
  # OUTSIDE the CommsAccess constraint. Identity is the recipient's random
  # token, never an id; unknown tokens 404. GET on the unsubscribe path only
  # confirms (scanner protection); the POST is the act, and RFC 8058
  # one-click unsubscribes land on it too.
  get  "e/o/:token",          to: "comms/tracking#open",     as: :comms_open
  get  "e/c/:token/:link_id", to: "comms/tracking#click",    as: :comms_click
  get  "e/u/:token",          to: "comms/unsubscribes#show", as: :comms_unsubscribe
  post "e/u/:token",          to: "comms/unsubscribes#create"

  # Common Questions — reusable sets attached to many Vertos
  resources :common_question_sets, path: "common-question-sets" do
    collection do
      post :generate
    end
    member do
      get  :results
      post :add_question
      patch  "questions/:question_id", to: "common_question_sets#update_question", as: :update_question
      delete "questions/:question_id", to: "common_question_sets#destroy_question", as: :destroy_question
    end
  end

  # Partnerships — named groups of orgs
  resources :partnerships, except: [ :edit, :update ] do
    resources :partnership_invites,     only: [ :create ]
    resources :partnership_accounts,    only: [ :new, :create ]
    resources :partnership_vertos,      only: [ :create, :destroy, :show ]
    resources :partnership_common_question_sets, only: [ :create, :destroy ]
    resources :partnership_memberships, only: [ :destroy ]
  end

  # Owner-created partner account: partner sets their own password here
  # (emailed by PartnershipAccountMailer), never told it by the owner.
  resources :partner_account_setups, param: :token, only: [ :edit, :update ]

  # Funders — orgs that license a fixed number of seats to other orgs
  resources :funders, except: [ :edit, :update, :destroy ] do
    resources :funder_invites,     only: [ :create ]
    resources :funder_accounts,    only: [ :new, :create ]
    resources :funder_memberships, only: [ :update ]

    # Portfolios — a funder's grantee orgs grouped by theme, with a shared
    # Common Question bank that auto-populates into each grantee's own Verto.
    # Created via a modal on the Funder dashboard, so there's no :new page.
    resources :portfolios, except: [ :edit, :update, :new ] do
      resources :portfolio_memberships, only: [ :create, :destroy ]
      resources :portfolio_common_question_sets, only: [ :create, :destroy ]
      member do
        get  :results
        post :resync
      end
    end
  end

  # Public funder-invite acceptance (no auth)
  get  "funder_invites/:token",        to: "funder_invite_acceptances#show",   as: :funder_invite
  post "funder_invites/:token/accept", to: "funder_invite_acceptances#accept", as: :accept_funder_invite

  # Owner-created licensed-org account: they set their own password here
  # (emailed by FunderAccountMailer), never told it by the owner.
  resources :funder_account_setups, param: :token, only: [ :edit, :update ]
end
