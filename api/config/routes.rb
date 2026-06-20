Rails.application.routes.draw do
  namespace :api do
    namespace :demo do
      get "profile", to: "households#profile"
      get "dashboard", to: "households#dashboard"
      get "optionality", to: "households#optionality"
      get "cfo-filter", to: "households#cfo_filter"
      resources :mia, only: [] do
        collection do
          get "messages", to: "mia_messages#index"
          post "messages", to: "mia_messages#create"
        end
      end
    end
  end

  get "up" => "rails/health#show", as: :rails_health_check
end
