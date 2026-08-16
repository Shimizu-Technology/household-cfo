module Api
  module V1
    module Admin
      class PlaidHealthController < BaseController
        before_action :authenticate_user!
        before_action :require_admin!

        def index
          items = PlaidItem.connected.includes(:plaid_accounts, :household, :connected_by_user).order(created_at: :desc)
          rows = items.map { |item| serialize_item(item) }

          render json: {
            summary: {
              connected: rows.length,
              healthy: rows.count { |row| row.dig(:health, :state) == "healthy" },
              attention_required: rows.count { |row| row.dig(:health, :requires_attention) }
            },
            items: rows
          }
        end

        private

        def serialize_item(item)
          {
            id: item.id,
            household: { id: item.household.id, name: item.household.name },
            connected_by: {
              id: item.connected_by_user.id,
              full_name: item.connected_by_user.full_name,
              email: item.connected_by_user.email
            },
            institution_name: item.institution_name,
            environment: item.environment,
            status: item.status,
            error_code: item.error_code,
            account_count: item.plaid_accounts.count(&:active?),
            connected_at: item.consented_at,
            health: PlaidIntegration::ItemHealth.new(item).as_json
          }
        end
      end
    end
  end
end
