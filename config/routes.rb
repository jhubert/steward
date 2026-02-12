Rails.application.routes.draw do
  post 'webhooks/telegram/:agent_id', to: 'webhooks#telegram'

  # Health check
  get 'up' => 'rails/health#show', as: :rails_health_check
end
