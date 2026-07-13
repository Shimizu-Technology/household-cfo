module Api
  module V1
    module Plaid
      class ItemsController < BaseController
        before_action :authenticate_user!

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
          items = current_household.plaid_items.order(created_at: :desc).includes(:plaid_accounts)
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
            institution_name: item.institution_name,
            status: item.status,
            environment: item.environment,
            consented_at: item.consented_at,
            last_synced_at: item.last_synced_at,
            error_message: item.error_message,
            disconnected_at: item.disconnected_at,
            accounts: item.plaid_accounts.map do |account|
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
                active: account.active
              }
            end
          }
        end
      end
    end
  end
end
