Rails.application.routes.draw do
  # Public player (no auth)
  get  "play/:token",        to: "player#show",   as: :play_survey
  post "play/:token/submit", to: "player#submit", as: :submit_survey

  # Auth
  resource  :session,   only: [:new, :create, :destroy]
  resources :passwords, param: :token, only: [:new, :create, :edit, :update]

  # Org switcher
  post "switch_organisation", to: "organisations#switch", as: :switch_organisation

  # Org management (admin only)
  resources :organisations, only: [:edit, :update] do
    resources :memberships, only: [:index, :new, :create, :destroy]
  end

  # Health + PWA
  get "up"             => "rails/health#show", as: :rails_health_check
  get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker
  get "manifest"       => "rails/pwa#manifest",       as: :pwa_manifest

  # App
  root "surveys#index"
  get  "surveys/new",                 to: "surveys#new",     as: :new_survey
  post "surveys/generate",            to: "surveys#generate", as: :generate_survey
  post "surveys/:id/publish",         to: "surveys#publish",  as: :publish_survey
  get  "surveys/:id/results",         to: "surveys#results",  as: :survey_results
  get  "surveys/:id/results/summary", to: "survey_summaries#show",  as: :survey_results_summary
  post "surveys/:survey_id/chat",     to: "survey_chats#create",    as: :survey_chat
  resources :surveys, only: [:show, :update]
end
