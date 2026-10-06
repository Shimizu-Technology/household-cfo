module HouseholdFinance
  module FinancialRestart
    class BankResume
      def initialize(item, user:)
        @item, @user = item, user
      end

      def call(accepted:, expected_item_financial_generation:)
        raise ArgumentError, "Review and accept using newly received bank activity." unless accepted == true
        item.with_lock do
          household = item.household
          household.with_lock do
            FinancialGenerationGuard.request!(household)
            actor = User.find_by(id: user.id)
            writable = actor && !actor.revoked? && household.household_memberships.exists?(user_id: actor.id, role: %w[owner partner])
            raise ArgumentError, "This household is read-only for your account." unless writable
            ChallengePrivacy::PrivateFinanceAccess.authorize!(household, user: actor)
            raise ArgumentError, "This bank connection is disconnected." unless item.connected?
            return item if item.financial_generation == household.financial_generation
            unless expected_item_financial_generation.is_a?(Integer) && expected_item_financial_generation == item.financial_generation
              raise Operations::Base::StaleOperation, "This bank connection changed. Refresh its review; nothing changed."
            end
            previous = item.financial_generation
            item.update!(financial_generation: household.financial_generation, financial_resumed_at: Time.current, auto_confirm_trusted_merchants: false)
            household.household_audit_events.create!(user: actor, actor_type: "user", event_type: "plaid_item.financial_picture_resumed",
              auditable_type: "PlaidItem", auditable_id: item.id, occurred_at: Time.current,
              metadata: { previous_generation: previous, financial_generation: household.financial_generation,
                retained_transaction_count: item.plaid_transactions.where.not(financial_generation: household.financial_generation).count })
            item
          end
        end
      end

      private
      attr_reader :item, :user
    end
  end
end
