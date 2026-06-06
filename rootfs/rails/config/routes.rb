# Minimal routes for client Docker image — the client never serves HTTP,
# but Rails requires a routes file to boot. Only the health check is defined.
Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check
end
