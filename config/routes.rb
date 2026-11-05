Rails.application.routes.draw do
  # The market screen: ladder, tape, ticket, replay scrubber.
  root "books#show"
  get "books/:symbol", to: "books#show", as: :book

  # Intent travels over HTTP so it can be durable before the engine sees it.
  post   "books/:symbol/orders",               to: "orders#create",  as: :book_orders
  patch  "books/:symbol/orders/:order_id",     to: "orders#update"
  delete "books/:symbol/orders/:order_id",     to: "orders#destroy"

  get "metrics", to: "metrics#show"

  namespace :api do
    get "markets",              to: "markets#index", as: :markets
    get "books/:symbol",        to: "books#show",    as: :book
    get "books/:symbol/replay", to: "replays#show",  as: :book_replay
    get "books/:symbol/fills",  to: "fills#index",   as: :book_fills
  end

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check
end
