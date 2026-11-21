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
          audit!(bill, "removed", before: bill.amount_cents)
        end
        render json: { saved: true }
      end

      # Only her answer marks a one-time bill paid (or not paid after all); a paid bill stops counting.
      def paid
        current_household.with_lock do
          bill = scope.find(params[:id])
          return render json: { errors: [ "Only a one-time bill can be marked paid." ] }, status: :unprocessable_entity unless bill.one_time?

          paid = ActiveModel::Type::Boolean.new.cast(params.fetch(:paid, true))
          bill.update!(paid_on: paid ? Date.current : nil)
          audit!(bill, paid ? "paid" : "unpaid", before: bill.amount_cents, after: bill.amount_cents)
        end
        render json: { saved: true }
      end

      private

      def scope = current_household.bills.current_picture

      def audit!(bill, action, before: nil, after: nil)
        current_household.household_audit_events.create!(actor_type: "user", user: current_user,
          event_type: "bill.#{action}", auditable_type: "Bill", auditable_id: bill.id, occurred_at: Time.current,
          metadata: { name: bill.name, amount_cents_before: before, amount_cents_after: after, due_on: bill.due_on&.iso8601, repeat_months: bill.repeat_months, paid_on: bill.paid_on&.iso8601 })
      end

      def save_bill(bill, status)
        values = params.require(:bill).permit(:name, :amount, :due_on, :repeat_months, :must_pay, :estimate, :budget_category_id).to_h
        amount = values.delete("amount")
        values[:amount_cents] = HouseholdFinance::Money.cents!(amount) unless amount.nil?
        # A repeating bill has no single payment to mark paid.
        values[:paid_on] = nil if values["repeat_months"].present?
        current_household.with_lock do
          before = bill.new_record? ? nil : bill.amount_cents_was
          created = bill.new_record?
          bill.update!(values)
          audit!(bill, created ? "created" : "updated", before: before, after: bill.amount_cents)
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
