Rails.application.routes.draw do
  post 'webhooks/telegram/:agent_id', to: 'webhooks#telegram'
  post 'webhooks/email', to: 'webhooks#email'

  # Google OAuth setup flow (signed token-based auth)
  get  'setup/google/:token', to: 'setup#show', as: :google_setup
  post 'setup/google/:token/start', to: 'setup#start', as: :google_setup_start
  post 'setup/google/:token/complete', to: 'setup#complete', as: :google_setup_complete

  mount MissionControl::Jobs::Engine, at: "/admin/jobs"

  namespace :admin do
    root to: 'agents#index'
    resources :agents, only: [:index, :show, :new, :create, :edit, :update] do
      member do
        post :enable_skill
        post :disable_skill
      end
      resources :tools, controller: 'agent_tools', only: [:edit, :update] do
        member { patch :toggle }
      end
      resources :principals, controller: 'agent_principals', only: [:new, :create, :destroy]
    end
    resources :conversations, only: [:index, :show]
  end

  root 'home#index'

  # Health check
  get 'up' => 'rails/health#show', as: :rails_health_check
end
