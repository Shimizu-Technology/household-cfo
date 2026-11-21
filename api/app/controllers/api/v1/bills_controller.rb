module Api
  module V1
    class BillsController < BaseController
      before_action :authenticate_user!
      before_action :require_writable_household!

      def create
        save_bill(current_household.bills.new, :created)
      end

      def update
        save_bill(scope.find(params[:id]), :ok)
      end

      def destroy
        current_household.with_lock do
          bill = scope.find(params[:id])
          bill.destroy!
          audit!(bill, "removed")
        end
        render json: { saved: true }
      end

      private

      def scope = current_household.bills.current_picture

      def audit!(bill, action)
        current_household.household_audit_events.create!(actor_type: "user", user: current_user,
          event_type: "bill.#{action}", auditable_type: "Bill", auditable_id: bill.id, occurred_at: Time.current,
          metadata: { name: bill.name, amount_cents: bill.amount_cents })
      end

      def save_bill(bill, status)
        values = params.require(:bill).permit(:name, :amount, :due_on, :repeat_months, :must_pay, :estimate, :budget_category_id).to_h
        amount = values.delete("amount")
        values[:amount_cents] = HouseholdFinance::Money.cents!(amount) unless amount.nil?
        current_household.with_lock do
          bill.update!(values)
          audit!(bill, "saved")
        end
        render json: { saved: true }, status: status
      rescue ActiveRecord::RecordInvalid => error
        render json: { errors: error.record.errors.full_messages }, status: :unprocessable_entity
      rescue ArgumentError => error
        render json: { errors: [ error.message ] }, status: :unprocessable_entity
      end
    end
  end
end
