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
  get  "play/:token/location_search", to: "player#location_search", as: :player_location_search

  # Test Mode: shareable while still editable, records nothing. Deliberately
  # OUTSIDE /play/ — the service worker's scope is /play/ only and it serves
  # player HTML stale-while-revalidate, which would pin a mutable test link
  # one edit behind forever (see app/javascript/sw_register.js).
  get "test/:token", to: "player#test_show", as: :test_survey

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
  post "surveys/finalize_import",     to: "surveys#finalize_import", as: :finalize_import_survey
  post "surveys/:id/publish",         to: "surveys#publish",  as: :publish_survey
  post "surveys/:id/unpublish",       to: "surveys#unpublish", as: :unpublish_survey
  post   "surveys/:id/test_link",     to: "surveys#enable_test_link",  as: :test_link_survey
  delete "surveys/:id/test_link",     to: "surveys#disable_test_link"
  post "surveys/:id/duplicate",       to: "surveys#duplicate", as: :duplicate_survey
  get  "surveys/:id/preview",         to: "surveys#preview",  as: :preview_survey
  get  "surveys/:id/qr",              to: "surveys#qr",       as: :qr_survey
  post "surveys/:id/card_image",      to: "surveys#card_image", as: :card_image_survey
  post "surveys/:id/card_lottie",     to: "surveys#card_lottie", as: :card_lottie_survey
  post "surveys/:id/settings",        to: "surveys#update_settings", as: :survey_settings
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
  delete "surveys/bulk_archive",        to: "surveys#bulk_archive",        as: :bulk_archive_surveys
  delete "surveys/bulk_destroy",        to: "surveys#bulk_destroy",        as: :bulk_destroy_surveys
  delete "surveys/:id/destroy_forever", to: "surveys#destroy_forever",     as: :destroy_forever_survey
  post   "surveys/:id/restore",          to: "surveys#restore",             as: :restore_survey
  resources :surveys, only: [ :show, :update, :destroy ]

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
