Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/*
  get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker
  get "manifest" => "rails/pwa#manifest", as: :pwa_manifest

  # Public player
  get  "play/:token",        to: "player#show",   as: :play_survey
  post "play/:token/submit", to: "player#submit", as: :submit_survey

  root "surveys#index"
  get  "surveys/new",       to: "surveys#new",    as: :new_survey
  post "surveys/generate",  to: "surveys#generate", as: :generate_survey
  post "surveys/:id/publish",    to: "surveys#publish",  as: :publish_survey
  get  "surveys/:id/results",         to: "surveys#results",  as: :survey_results
  get  "surveys/:id/results/summary", to: "surveys#results_summary", as: :survey_results_summary
  resources :surveys, only: [:show, :update]
end
