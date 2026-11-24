module Api
  module V1
    class BillsController < BaseController
      before_action :authenticate_user!
      before_action :require_writable_household!

      # A retried Save sends the same Idempotency-Key and gets back the bill it already saved.
      def create
        save_bill(current_household.bills.new(idempotency_key: request_idempotency_key), :created)
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
      rescue ActiveRecord::RecordInvalid => error
        render json: { errors: error.record.errors.full_messages }, status: :unprocessable_entity
      end

      private

      def scope = current_household.bills.current_picture

      def audit!(bill, action, before: nil, after: nil, past_due_before: bill.past_due_cents)
        current_household.household_audit_events.create!(actor_type: "user", user: current_user,
          event_type: "bill.#{action}", auditable_type: "Bill", auditable_id: bill.id, occurred_at: Time.current,
          metadata: { name: bill.name, amount_cents_before: before, amount_cents_after: after, due_on: bill.due_on&.iso8601, repeat_months: bill.repeat_months, paid_on: bill.paid_on&.iso8601,
            past_due_cents_before: past_due_before, past_due_cents_after: bill.past_due_cents })
      end

      def save_bill(bill, status)
        values = params.require(:bill).permit(:name, :amount, :due_on, :repeat_months, :must_pay, :estimate, :budget_category_id, :past_due).to_h
        amount = values.delete("amount")
        values[:amount_cents] = HouseholdFinance::Money.cents!(amount) unless amount.nil?
        # Blank clears it back to not entered; 0 means she is caught up.
        if values.key?("past_due")
          past_due = values.delete("past_due")
          values[:past_due_cents] = past_due.to_s.strip.blank? ? nil : HouseholdFinance::Money.cents!(past_due, message: "Past-due amount must be a number")
        end
        # A new bill with no past-due amount has none: a lost-response retry that leaves it out must match a blank
        # saved amount, so clearing it on the retry is a conflict rather than silently keeping the first amount.
        values[:past_due_cents] = nil if bill.new_record? && !values.key?(:past_due_cents)
        # A repeating bill has no single payment to mark paid.
        values[:paid_on] = nil if values["repeat_months"].present?
        replayed = false
        conflict = nil
        current_household.with_lock do
          HouseholdFinance::FinancialGenerationGuard.request!(current_household)
          created = bill.new_record?
          saved = scope.find_by(idempotency_key: bill.idempotency_key) if created
          if saved
            # A lost-response retry sends the same values; edits made after it must not be dropped silently.
            saved.assign_attributes(values)
            changed = saved.changed?
            saved.restore_attributes
            conflict = saved if changed
            bill, replayed = saved, true
            next
          end
          # The amount before this edit is the one committed now, not the one read before the lock.
          bill.reload unless created
          before = created ? nil : bill.amount_cents
          past_due_before = created ? nil : bill.past_due_cents
          bill.update!(values)
          audit!(bill, created ? "created" : "updated", before: before, after: bill.amount_cents, past_due_before: past_due_before)
        end
        if conflict
          return render json: { errors: [ "This bill was already saved before your changes. Refresh to see it, then edit it again." ], bill_id: conflict.id },
            status: :conflict
        end
        render json: { saved: true, bill_id: bill.id, replayed: replayed }, status: status
      rescue ActiveRecord::RecordInvalid => error
        render json: { errors: error.record.errors.full_messages }, status: :unprocessable_entity
      rescue HouseholdFinance::Operations::Base::StaleOperation
        raise
      rescue ArgumentError => error
        render json: { errors: [ error.message ] }, status: :unprocessable_entity
      end
    end
  end
end
