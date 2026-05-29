Rails.application.routes.draw do
  # Public player (no auth)
  get  "play/:token",        to: "player#show",   as: :play_survey
  post "play/:token/progress", to: "player#progress", as: :progress_survey
  post "play/:token/submit", to: "player#submit", as: :submit_survey
  get  "play/:token/results", to: "player#results", as: :player_results

  # Auth
  resource  :session,       only: [:new, :create, :destroy]
  resources :passwords,     param: :token, only: [:new, :create, :edit, :update]
  resources :registrations, only: [:new, :create]

  # Google Sheets export OAuth (callback is a GET — Google redirects via browser)
  get "google/connect",  to: "google_auth#connect",  as: :google_connect
  get "google/callback", to: "google_auth#callback", as: :google_callback

  # Org switcher
  post "switch_organisation", to: "organisations#switch", as: :switch_organisation

  # UI language switcher (works on public pages too)
  post "locale", to: "locales#update", as: :locale

  # Org management (admin only)
  resources :organisations, only: [:edit, :update] do
    resources :memberships, only: [:index, :destroy]
    resources :invites,     only: [:new, :create]
  end

  # Public invite acceptance (no auth)
  get  "invites/:token",        to: "invites#show",   as: :invite
  post "invites/:token/accept", to: "invites#accept", as: :accept_invite

  # Health + PWA
  get "up"             => "rails/health#show", as: :rails_health_check
  get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker
  get "manifest"       => "rails/pwa#manifest",       as: :pwa_manifest

  # App
  root "surveys#index"
  get  "surveys/new",                 to: "surveys#new",     as: :new_survey
  post "surveys/generate",            to: "surveys#generate", as: :generate_survey
  post "surveys/:id/publish",         to: "surveys#publish",  as: :publish_survey
  post "surveys/:id/settings",        to: "surveys#update_settings", as: :survey_settings
  post "surveys/:id/shuffle_assets",  to: "surveys#shuffle_assets",  as: :shuffle_survey_assets
  get  "surveys/:id/results",         to: "surveys#results",  as: :survey_results
  get  "surveys/:survey_id/results/export",       to: "results_exports#show",         as: :survey_results_export
  post "surveys/:survey_id/results/google_sheet", to: "google_sheets_exports#create", as: :survey_google_sheet
  post "surveys/:id/generate_card",   to: "surveys#generate_card", as: :generate_survey_card
  post "surveys/:id/render_card",     to: "surveys#render_card",   as: :render_survey_card
  get  "surveys/:id/results/summary", to: "survey_summaries#show",  as: :survey_results_summary
  post "surveys/:survey_id/chat",     to: "survey_chats#create",    as: :survey_chat
  delete "surveys/bulk_archive",        to: "surveys#bulk_archive",        as: :bulk_archive_surveys
  delete "surveys/bulk_destroy",        to: "surveys#bulk_destroy",        as: :bulk_destroy_surveys
  delete "surveys/:id/destroy_forever", to: "surveys#destroy_forever",     as: :destroy_forever_survey
  resources :surveys, only: [:show, :update, :destroy]

  # Alliances — named groups of orgs
  resources :alliances, except: [:edit, :update] do
    resources :alliance_invites,     only: [:create]
    resources :alliance_vertos,      only: [:create, :destroy, :show]
    resources :alliance_memberships, only: [:destroy]
  end
end
