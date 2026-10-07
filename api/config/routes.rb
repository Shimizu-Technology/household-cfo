Rails.application.routes.draw do
  namespace :api do
    namespace :auth do
      get "options", to: "browser_sessions#options"
      post "email/start", to: "browser_sessions#email_start"
      post "email/verify", to: "browser_sessions#email_verify"
      post "email/resend", to: "browser_sessions#email_resend"
      post "email/cancel", to: "browser_sessions#email_cancel"
      post "login", to: "browser_sessions#login"
      post "login/cancel", to: "browser_sessions#login_cancel"
      post "login/status", to: "browser_sessions#login_status"
      get "callback", to: "browser_sessions#callback"
      get "session", to: "browser_sessions#show"
      post "logout", to: "browser_sessions#logout"
    end
    namespace :public do
      resource :brand, only: :show
    end
    namespace :v1 do
      resources :enterprise_organizations, only: %i[index show create update] do
        member do
          post :portal
          post :reconcile
          get :audit
        end
        resources :memberships, only: %i[index update], controller: :enterprise_memberships
        resources :group_mappings, only: %i[index create update destroy], controller: :enterprise_group_mappings
      end
      get "participant_programs", to: "participant_programs#index"
      get "savings_challenge/debt", to: "savings_debt#show"
      get "savings_challenge/debt/records", to: "savings_debt#records"
      get "savings_challenge/debt/household_candidates", to: "savings_debt#household_candidates"
      get "savings_challenge/debt/source_candidates", to: "savings_debt#source_candidates"
      get "savings_challenge/debt/request_status", to: "savings_debt#request_status"
      post "savings_challenge/debt/actions/:review_action", to: "savings_debt#mutate"
      get "savings_challenge/daily", to: "savings_daily#show"
      get "savings_challenge/export", to: "savings_exports#show"
      get "savings_challenge/evidence", to: "savings_evidence#show"
      get "savings_challenge/evidence/candidates", to: "savings_evidence#candidates"
      get "savings_challenge/evidence/request_status", to: "savings_evidence#request_status"
      post "savings_challenge/evidence/actions/:review_action", to: "savings_evidence#mutate"
      get "savings_challenge/private_controls", to: "challenge_privacy#controls"
      get "savings_challenge/:enrollment_id/reminders", to: "challenge_reminders#show"
      get "savings_challenge/:enrollment_id/reminders/request_status", to: "challenge_reminders#request_status"
      post "savings_challenge/:enrollment_id/reminders/:reminder_action", to: "challenge_reminders#mutate"
      get "savings_challenge/daily/records", to: "savings_daily#records"
      get "savings_challenge/daily/candidates", to: "savings_daily#candidates"
      get "savings_challenge/daily/request_status", to: "savings_daily#request_status"
      post "savings_challenge/daily/actions/:review_action", to: "savings_daily#mutate"
      get "savings_challenge/daily/reflections/:id/erase_status", to: "savings_daily#erase_status"
      post "savings_challenge/daily/reflections/:id/erase", to: "savings_daily#erase_reflection"
      get "shared_challenges/:enrollment_id/basic", to: "shared_challenges#basic"
      get "shared_challenges/:enrollment_id/summary", to: "shared_challenges#summary"
      get "shared_challenges/:enrollment_id/scopes", to: "shared_challenges#scopes"
      get "shared_challenges/:enrollment_id/help", to: "shared_challenges#help"
      get "challenge_cohorts/:cohort_id/participants", to: "challenge_cohorts#participants"
      get "challenge_cohorts/:cohort_id/sponsor_exports", to: "challenge_cohorts#exports"
      post "challenge_cohorts/:cohort_id/sponsor_exports", to: "challenge_cohorts#approve_export"
      get "challenge_cohorts/:cohort_id/sponsor_exports/:id", to: "challenge_cohorts#export"
      get "shared_challenges/:enrollment_id/selected", to: "shared_challenges#selected"
      get "shared_challenges/:enrollment_id/source_content", to: "shared_challenges#source_content"
      get "shared_challenges/:enrollment_id/support/:ticket_id", to: "shared_challenges#support_ticket"
      patch "shared_challenges/:enrollment_id/support/:ticket_id", to: "shared_challenges#support_status"
      get "savings_challenge/:enrollment_id/privacy", to: "challenge_privacy#show"
      get "savings_challenge/:enrollment_id/privacy/request_status", to: "challenge_privacy#request_status"
      get "savings_challenge/:enrollment_id/privacy/selection_candidates", to: "challenge_privacy#selection_candidates"
      get "savings_challenge/:enrollment_id/source_use/:document_import_id", to: "challenge_privacy#source_use"
      %w[consent support_request support_grant support_revoke source_authorize source_revoke].each do |action|
        post "savings_challenge/:enrollment_id/privacy/#{action}", to: "challenge_privacy##{action}"
      end
      get "setup_help", to: "setup_help#show"
      post "setup_help/requests", to: "setup_help#create_request"
      post "setup_help/requests/:id/cancel", to: "setup_help#cancel_request"
      post "setup_help/requests/:id/reopen", to: "setup_help#reopen_request"
      get "setup_help/restart/status", to: "setup_help#restart_status"
      post "setup_help/restart/preview", to: "setup_help#restart_preview"
      post "setup_help/restart/apply", to: "setup_help#restart_apply"
      post "setup_help/restart/cancel", to: "setup_help#restart_cancel"
      resources :setup_support_requests, only: :index do
        member do
          post :triage
          post :prepare
          post :decline
        end
      end
      get "financial_restart/status", to: "financial_restarts#status"
      post "financial_restart/preview", to: "financial_restarts#preview"
      post "financial_restart/cancel", to: "financial_restarts#cancel"
      post "financial_restart/apply", to: "financial_restarts#apply"
      get "financial_baseline", to: "financial_baselines#show"
      get "financial_baseline/observations", to: "financial_baselines#observations"
      get "financial_baseline/request_status", to: "financial_baselines#request_status"
      get "financial_baseline/context", to: "financial_baselines#context"
      get "financial_baseline/history", to: "financial_baselines#history"
      post "financial_baseline/preview", to: "financial_baselines#preview"
      post "financial_baseline/approve", to: "financial_baselines#approve"
      post "financial_baseline/revise", to: "financial_baselines#revise"
      get "savings_challenge", to: "savings_challenges#show"
      get "savings_challenge/request_status", to: "savings_challenges#request_status"
      post "savings_challenge/enrollment", to: "savings_challenges#enroll"
      post "savings_challenge/plan_drafts", to: "savings_challenges#stage_plan"
      post "savings_challenge/plan_drafts/:id/approve", to: "savings_challenges#approve_plan"
      post "savings_challenge/entry_drafts", to: "savings_challenges#stage_entry"
      post "savings_challenge/entry_drafts/:id/approve", to: "savings_challenges#approve_entry"
      post "savings_challenge/zero_attestations", to: "savings_challenges#attest_zero"
      %w[entries entry_versions entry_drafts plan_versions plan_drafts zero_attestations].each do |collection|
        get "savings_challenge/#{collection}", to: "savings_challenges##{collection}"
      end
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
      get "source_review_accounts", to: "source_reviews#accounts"
      get "document_imports/:document_import_id/review_candidates", to: "source_reviews#candidates"
      get "document_imports/:document_import_id/review_request_status", to: "source_reviews#request_status"
      post "document_imports/:document_import_id/review/:review_action", to: "source_reviews#mutate"
      resources :document_imports, only: %i[index show create destroy] do
        collection do
          post :presign
          post :complete
        end
        member do
          post :reprocess
          post :apply
          get :source_url
          get :source_content
          get :source_review
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
            post :resume_financial_picture
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
      resources :pilot_feedback_reports, only: %i[index create] do
        patch :withdraw_support_access, on: :member
      end
      namespace :admin do
        resources :coach_workspaces, only: %i[show create update]
        resources :collaborators, controller: "workspace_collaborators", only: %i[index create update destroy] do
          post :send_invitation, on: :member
        end
        resource :brand, controller: "workspace_brand_configurations", only: %i[show update] do
          post :preview
          post :publish
          resources :versions, controller: "workspace_brand_versions", only: :show do
            post :rollback, on: :member
          end
        end
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
          resource :launch, controller: "cohort_release_launches", only: %i[show create]
          delete "participants/:user_id", action: :remove_participant, on: :member
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
