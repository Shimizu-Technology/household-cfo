module Api
  module V1
    class DebtsController < BaseController
      before_action :authenticate_user!
      before_action :require_writable_household!
      before_action :set_debt, only: %i[update destroy]

      def create
        debt = current_household.debts.create!(normalized_params)
        audit!(debt, "debt.created")
        render json: { debt: serialize(debt) }, status: :created
      rescue ArgumentError => e
        render json: { errors: [ e.message ] }, status: :unprocessable_entity
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      end

      def update
        @debt.update!(normalized_params)
        audit!(@debt, "debt.updated")
        render json: { debt: serialize(@debt) }
      rescue ArgumentError => e
        render json: { errors: [ e.message ] }, status: :unprocessable_entity
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      end

      def destroy
        debt_id = @debt.id
        @debt.destroy!
        current_household.household_audit_events.create!(user: current_user, actor_type: "user", event_type: "debt.deleted", metadata: { debt_id: debt_id }, occurred_at: Time.current)
        head :no_content
      end

      private

      def set_debt
        @debt = current_household.debts.find(params[:id])
      end

      def normalized_params
        permitted = params.require(:debt).permit(:label, :debt_type, :balance, :minimum_payment, :interest_rate_percent)
        attributes = permitted.slice(:label, :debt_type, :interest_rate_percent).to_h
        attributes[:interest_rate_percent] = nil if permitted.key?(:interest_rate_percent) && permitted[:interest_rate_percent].blank?
        attributes[:balance_cents] = HouseholdFinance::Money.cents!(permitted[:balance], message: "Balance must be a number with no more than two decimal places") if permitted.key?(:balance)
        attributes[:minimum_payment_cents] = HouseholdFinance::Money.cents!(permitted[:minimum_payment], message: "Minimum payment must be a number with no more than two decimal places") if permitted.key?(:minimum_payment)
        attributes
      end

      def serialize(debt)
        {
          id: debt.id,
          label: debt.label,
          debt_type: debt.debt_type,
          balance: HouseholdFinance::Money.dollars(debt.balance_cents),
          minimum_payment: HouseholdFinance::Money.dollars(debt.minimum_payment_cents),
          interest_rate_percent: debt.interest_rate_percent&.to_f
        }
      end

      def audit!(debt, event_type)
        current_household.household_audit_events.create!(
          user: current_user,
          actor_type: "user",
          event_type: event_type,
          auditable_type: "Debt",
          auditable_id: debt.id,
          metadata: { debt_type: debt.debt_type },
          occurred_at: Time.current
        )
      end
    end
  end
end
