module Api
  module V1
    module Plaid
      class ItemsController < BaseController
        before_action :authenticate_user!
        before_action :require_writable_household!, except: :index

        def index
          render json: payload
        end

        def link_token
          return render json: { errors: [ "Review and accept the bank-data consent before connecting." ] }, status: :unprocessable_entity unless ActiveModel::Type::Boolean.new.cast(params[:consent_accepted])

          token = PlaidIntegration::LinkToken.new(household: current_household, user: current_user).call
          render json: { link_token: token, consent_policy_version: PlaidIntegration::Configuration::CONSENT_POLICY_VERSION }
        rescue PlaidIntegration::Error => e
          render json: { errors: [ e.message ] }, status: :service_unavailable
        end

        def update_link_token
          item = current_household.plaid_items.syncable.find(params[:id])
          token = PlaidIntegration::LinkToken.new(household: current_household, user: current_user, plaid_item: item).call
          render json: { link_token: token }
        rescue ActiveRecord::RecordNotFound
          render json: { errors: [ "Bank connection not found" ] }, status: :not_found
        rescue PlaidIntegration::Error => e
          render json: { errors: [ e.message ] }, status: :service_unavailable
        end

        def exchange
          item = PlaidIntegration::ItemConnector.new(
            household: current_household,
            user: current_user,
            public_token: params[:public_token],
            institution_id: params[:institution_id],
            institution_name: params[:institution_name]
          ).call
          render json: { item: serialize_item(item), plaid: payload }, status: :created
        rescue PlaidIntegration::Error => e
          render json: { errors: [ e.message ] }, status: :unprocessable_entity
        end

        def sync
          item = current_household.plaid_items.syncable.find(params[:id])
          PlaidTransactionSyncJob.perform_later(item.id)
          render json: payload, status: :accepted
        rescue ActiveRecord::RecordNotFound
          render json: { errors: [ "Bank connection not found" ] }, status: :not_found
        rescue PlaidIntegration::Error => e
          render json: { errors: [ e.message ] }, status: :unprocessable_entity
        end

        def resume_financial_picture
          item = current_household.plaid_items.find(params[:id])
          HouseholdFinance::FinancialRestart::BankResume.new(item, user: current_user).call(
            accepted: params[:accepted], expected_item_financial_generation: params[:expected_item_financial_generation])
          PlaidTransactionSyncJob.perform_later(item.id)
          render json: payload
        rescue ActiveRecord::RecordNotFound
          render json: { errors: [ "Bank connection not found" ] }, status: :not_found
        rescue ArgumentError, ActiveRecord::RecordInvalid => error
          render json: { errors: [ error.message ] }, status: :unprocessable_entity
        end

        def update
          item = current_household.plaid_items.connected.find(params[:id])
          item.update!(auto_confirm_trusted_merchants: ActiveModel::Type::Boolean.new.cast(params[:auto_confirm_trusted_merchants]))
          current_household.household_audit_events.create!(
            user: current_user,
            actor_type: "user",
            event_type: "plaid_item.review_preferences_updated",
            auditable_type: "PlaidItem",
            auditable_id: item.id,
            occurred_at: Time.current,
            metadata: { auto_confirm_trusted_merchants: item.auto_confirm_trusted_merchants }
          )
          render json: payload
        rescue ActiveRecord::RecordNotFound
          render json: { errors: [ "Bank connection not found" ] }, status: :not_found
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        end

        def destroy
          item = current_household.plaid_items.connected.find(params[:id])
          PlaidIntegration::ItemDisconnector.new(item, user: current_user).call
          render json: payload
        rescue ActiveRecord::RecordNotFound
          render json: { errors: [ "Bank connection not found" ] }, status: :not_found
        rescue PlaidIntegration::Error => e
          render json: { errors: [ e.message ] }, status: :unprocessable_entity
        end

        private

        def payload
          items = current_household.plaid_items.order(created_at: :desc).includes(plaid_accounts: :account)
          {
            configured: PlaidIntegration::Configuration.configured?,
            environment: PlaidIntegration::Configuration.configured? ? PlaidIntegration::Configuration.environment : nil,
            consent_policy_version: PlaidIntegration::Configuration::CONSENT_POLICY_VERSION,
            items: items.map { |item| serialize_item(item) }
          }
        rescue PlaidIntegration::Error
          { configured: false, environment: nil, consent_policy_version: PlaidIntegration::Configuration::CONSENT_POLICY_VERSION, items: [] }
        end

        def serialize_item(item)
          {
            id: item.id,
            financial_generation: item.financial_generation,
            context_paused_by_restart: !item.current_financial_picture?,
            financial_resumed_at: item.financial_resumed_at&.iso8601,
            institution_name: item.institution_name,
            status: item.status,
            environment: item.environment,
            consented_at: item.consented_at,
            last_synced_at: item.last_synced_at,
            health: PlaidIntegration::ItemHealth.new(item).as_json,
            error_message: item.error_message,
            disconnected_at: item.disconnected_at,
            auto_confirm_trusted_merchants: item.auto_confirm_trusted_merchants,
            accounts: item.plaid_accounts.map do |account|
              eligibility = PlaidIntegration::AccountEligibility.new(account)
              {
                id: account.id,
                name: account.name,
                official_name: account.official_name,
                mask: account.mask,
                type: account.account_type,
                subtype: account.account_subtype,
                current_balance_cents: account.current_balance_cents,
                available_balance_cents: account.available_balance_cents,
                currency: account.iso_currency_code,
                active: account.active,
                eligible_for_asset_tracking: eligibility.eligible? && eligibility.active_observation?,
                allowed_account_types: eligibility.allowed_account_types,
                suggested_account_type: eligibility.suggested_account_type,
                canonical_account_id: account.account&.id,
                canonical_balance_known: account.account&.balance_known?,
                canonical_balance_cents: account.account&.balance_known? ? account.account.balance_cents : nil,
                observation_newer_than_saved: account.account.present? && account.current_balance_cents.present? && item.last_synced_at.present? &&
                  (account.account.plaid_reconciled_at.nil? || item.last_synced_at.to_i > account.account.plaid_reconciled_at.to_i)
              }
            end
          }
        end
      end
    end
  end
end
