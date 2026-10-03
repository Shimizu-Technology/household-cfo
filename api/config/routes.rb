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
      get "spending_report", to: "spending_reports#show"
      get "wealth", to: "households#wealth"
      get "optionality", to: "households#optionality"
      get "cfo-filter", to: "households#cfo_filter"
      resources :mia, only: [] do
        collection do
          get "messages", to: "mia_messages#index"
          post "messages", to: "mia_messages#create"
          delete "messages", to: "mia_messages#destroy"
          post "transcriptions", to: "mia_transcriptions#create"
        end
      end
      resources :budget_categories, only: %i[create update destroy] do
        post :restore, on: :member
      end
      resources :budget_allocations, only: :update
      resources :debts, only: %i[create update destroy] do
        member { post :restore }
        collection { patch :tracking }
      end
      resources :accounts, only: %i[create update destroy] do
        member do
          post :restore
          post :plaid_link
          post :plaid_reconcile
          delete :plaid_link, action: :plaid_unlink
        end
      end
      resources :goals, only: %i[create update destroy] do
        post :restore, on: :member
      end
      resources :income_sources, only: %i[create update destroy] do
        post :restore, on: :member
      end
      resources :income_schedule_entries, only: %i[create update destroy]
      resources :mia_action_drafts, only: [] do
        member do
          post :apply
          post :cancel
        end
      end
      resources :household_memories, only: %i[index create update destroy] do
        member do
          post :confirm
          post :reject
        end
      end
      resource :mia_memory_settings, only: :update
      resources :transaction_drafts, only: %i[create update] do
        collection do
          post :bulk_confirm
          post :bulk_ignore
        end
        member do
          post :confirm
          post :ignore
          post :match
          post :reopen
        end
      end
      resources :document_imports, only: %i[index show create destroy] do
        collection do
          post :presign
          post :complete
        end
        member do
          post :reprocess
          post :apply
          get :source_url
          get :source_preview
          delete :source, action: :destroy_source
        end
        resources :items, only: :update, controller: "document_import_items"
      end
      namespace :plaid do
        resources :items, only: %i[index update destroy] do
          collection do
            post :link_token
            post :exchange
          end
          member do
            post :sync
            post :update_link_token
          end
        end
        resources :transactions, only: :index do
          collection do
            post :stage
            post :ignore
          end
        end
      end
      resources :pilot_feedback_reports, only: :create
      namespace :admin do
        get "plaid_health", to: "plaid_health#index"
        resources :personas, controller: "mia_personas", only: %i[index show create update destroy] do
          resources :phrase_promotions, controller: "persona_phrase_promotions", only: :create do
            post :restore, on: :member
          end
          resources :setup_sessions, controller: "persona_setup_sessions", only: %i[create show destroy] do
            post :rebase, on: :member
            resources :turns, controller: "persona_setup_turns", only: :create
            resources :proposals, controller: "persona_setup_proposals", only: [] do
              post :apply, on: :member
              post :reject, on: :member
            end
          end
          get :assignable_cohorts, on: :collection
          post :preview, on: :member
          post :publish, on: :member
          post :restore, on: :member
          resources :versions, controller: "mia_persona_versions", only: :show do
            post :rollback, on: :member
          end
          resource :content_packs, controller: "persona_content_packs", only: :update
          resource :release_readiness, controller: "persona_release_readiness", only: :show
          resources :evaluation_cases, controller: "persona_evaluation_cases", only: %i[index create destroy]
          resources :evaluation_runs, controller: "persona_evaluation_runs", only: %i[index show create] do
            resource :approval, controller: "persona_evaluation_approvals", only: :create
          end
          resources :audience_attestations, controller: "persona_audience_attestations", only: :create
        end
        resources :content_items, controller: "coach_content_items", only: %i[index create update destroy] do
          post :approve, on: :member
        end
        resources :content_packs, controller: "coach_content_packs", only: %i[index create update destroy] do
          post :publish, on: :member
        end
        resources :content_sources, controller: "coach_content_sources", only: %i[index show] do
          resources :phrase_proposals, controller: "coach_phrase_proposals", only: %i[index create]
          collection do
            post :presign
            post :complete
            post :retry_upload_cleanups
          end
          member do
            post :reprocess
            get :source_url
            delete :source, action: :destroy_source
          end
          resources :candidates, controller: "coach_content_source_candidates", only: :update do
            member do
              post :accept
              post :reject
            end
          end
        end
        resources :content_source_url_intakes, controller: "coach_content_source_url_intakes", only: %i[index create show destroy] do
          post :retry_cleanup, on: :member
        end
        resources :phrase_proposals, controller: "coach_phrase_proposals", only: %i[show update] do
          post :submit, on: :member
          resource :attestation, controller: "coach_phrase_attestations", only: :create
        end
        resources :cohorts, only: %i[index show create update] do
          resources :releases, controller: "cohort_releases", only: %i[index create] do
            post :restore, on: :member
          end
          resources :rollouts, controller: "cohort_rollouts", only: %i[index show create] do
            member do
              post :advance
              post :pause
              post :resume
              post :cancel
              post :rollback
            end
          end
          resource :persona_assignment, controller: "persona_assignments", only: %i[show update destroy]
          resource :experience_configuration, controller: "cohort_experience_configurations", only: %i[show update] do
            post :preview
            post :publish
            resources :versions, controller: "cohort_experience_versions", only: :show do
              post :rollback, on: :member
            end
          end
        end
        resources :pilot_feedback_reports, only: %i[index show update] do
          get :screenshot_url, on: :member
        end
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
  post "api/plaid/webhook", to: "api/plaid_webhooks#create"
end
