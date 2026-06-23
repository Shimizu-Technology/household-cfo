Rails.application.routes.draw do
  namespace :api do
    namespace :v1 do
      get "auth/me", to: "auth#me"
      resource :workspace, only: :show do
        patch "setup", on: :collection
      end
      get "profile", to: "households#profile"
      get "dashboard", to: "households#dashboard"
      get "budget", to: "households#budget"
      get "wealth", to: "households#wealth"
      get "optionality", to: "households#optionality"
      get "cfo-filter", to: "households#cfo_filter"
      resources :mia, only: [] do
        collection do
          get "messages", to: "mia_messages#index"
          post "messages", to: "mia_messages#create"
          delete "messages", to: "mia_messages#destroy"
        end
      end
      namespace :admin do
        resources :cohorts, only: %i[index show create update]
        resources :users, only: %i[index create update]
      end
    end

    namespace :demo do
      get "profile", to: "households#profile"
      get "dashboard", to: "households#dashboard"
      get "budget", to: "households#budget"
      get "wealth", to: "households#wealth"
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
