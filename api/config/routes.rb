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
      resources :budget_categories, only: %i[create update destroy]
      resources :budget_allocations, only: :update
      resources :transaction_drafts, only: [] do
        member do
          post :confirm
          post :ignore
        end
      end
      resources :document_imports, only: %i[index show create destroy] do
        member do
          post :reprocess
          post :apply
          get :source_url
          get :source_preview
          delete :source, action: :destroy_source
        end
        resources :items, only: :update, controller: "document_import_items"
      end
      namespace :admin do
        resources :cohorts, only: %i[index show create update]
        resources :users, only: %i[index create update] do
          post :resend_invitation, on: :member
        end
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
