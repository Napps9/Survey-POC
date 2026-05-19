Rails.application.routes.draw do
  # Public player (no auth)
  get  "play/:token",        to: "player#show",   as: :play_survey
  post "play/:token/submit", to: "player#submit", as: :submit_survey
  get  "play/:token/results", to: "player#results", as: :player_results

  # Auth
  resource  :session,       only: [:new, :create, :destroy]
  resources :passwords,     param: :token, only: [:new, :create, :edit, :update]
  resources :registrations, only: [:new, :create]

  # Org switcher
  post "switch_organisation", to: "organisations#switch", as: :switch_organisation

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
  get  "surveys/:id/results",         to: "surveys#results",  as: :survey_results
  get  "surveys/:id/results/summary", to: "survey_summaries#show",  as: :survey_results_summary
  post "surveys/:survey_id/chat",     to: "survey_chats#create",    as: :survey_chat
  get  "surveys/:survey_id/shares", to: "survey_shares#index",  as: :survey_shares
  post "surveys/:survey_id/shares", to: "survey_shares#create", as: :create_survey_share
  delete "surveys/:survey_id/shares/:id", to: "survey_shares#destroy", as: :survey_share

  resources :surveys, only: [:show, :update, :destroy]

  # Alliances (partner orgs)
  resources :alliances, only: [:index, :show, :destroy]
  resources :alliance_invites, only: [:create]

  # Partner-side dashboard
  get "alliance_vertos",     to: "alliance_vertos#index", as: :alliance_vertos
  get "alliance_vertos/:id", to: "alliance_vertos#show",  as: :alliance_verto
end
