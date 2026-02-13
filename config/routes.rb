Rails.application.routes.draw do
  post 'webhooks/telegram/:agent_id', to: 'webhooks#telegram'

  # Google OAuth setup flow (signed token-based auth)
  get  'setup/google/:token', to: 'setup#show', as: :google_setup
  post 'setup/google/:token/start', to: 'setup#start', as: :google_setup_start
  post 'setup/google/:token/complete', to: 'setup#complete', as: :google_setup_complete

  # Health check
  get 'up' => 'rails/health#show', as: :rails_health_check
end
