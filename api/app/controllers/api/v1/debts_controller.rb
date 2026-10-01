module Api
  module V1
    class DebtsController < BaseController
      before_action :authenticate_user!
      before_action :require_writable_household!

      def create
        result = runner.run(operation_key: "debt.record.create", input: debt_params.to_h.merge(source_type: "manual_ui"), idempotency_key: required_idempotency_key)
        render_debt_response(result.subject, status: :created)
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      rescue ActiveRecord::RecordNotUnique
        render json: { errors: [ "An active debt already uses that name and type" ] }, status: :unprocessable_entity
      rescue ArgumentError => e
        render_operation_error(e)
      end

      def update
        result = runner.run(operation_key: "debt.record.update", input: debt_params.to_h.merge(debt_id: scoped_debt.id), idempotency_key: required_idempotency_key)
        render_debt_response(result.subject)
      rescue ActiveRecord::RecordNotFound
        render json: { errors: [ "Debt not found" ] }, status: :not_found
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      rescue ActiveRecord::RecordNotUnique
        render json: { errors: [ "An active debt already uses that name and type" ] }, status: :unprocessable_entity
      rescue ArgumentError => e
        render_operation_error(e)
      end

      def destroy
        result = runner.run(operation_key: "debt.record.archive", input: { debt_id: scoped_debt.id }, idempotency_key: required_idempotency_key)
        render_debt_response(result.subject)
      rescue ActiveRecord::RecordNotFound
        render json: { errors: [ "Debt not found" ] }, status: :not_found
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      rescue ArgumentError => e
        render_operation_error(e)
      end

      def restore
        result = runner.run(operation_key: "debt.record.restore", input: { debt_id: scoped_debt.id }, idempotency_key: required_idempotency_key)
        render_debt_response(result.subject)
      rescue ActiveRecord::RecordNotFound
        render json: { errors: [ "Debt not found" ] }, status: :not_found
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      rescue ActiveRecord::RecordNotUnique
        render json: { errors: [ "An active debt already uses that name and type" ] }, status: :unprocessable_entity
      rescue ArgumentError => e
        render_operation_error(e)
      end

      def tracking
        result = runner.run(operation_key: "debt.tracking_mode.update", input: tracking_params.to_h, idempotency_key: required_idempotency_key)
        render json: { debt_portfolio: HouseholdFinance::DebtPortfolio.new(result.subject.household).as_json }
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      rescue ArgumentError => e
        render_operation_error(e)
      end

      private

      def runner
        @runner ||= HouseholdFinance::Operations::Runner.new(current_household, user: current_user)
      end

      def required_idempotency_key
        request.headers["Idempotency-Key"].to_s.strip.presence || raise(ArgumentError, "Idempotency-Key header is required")
      end

      def scoped_debt
        @scoped_debt ||= current_household.debts.find(params[:id])
      end

      def debt_params
        params.fetch(:debt, {}).permit(:label, :debt_type, :balance, :minimum_payment, :interest_rate_percent)
      end

      def tracking_params
        params.fetch(:debt_tracking, {}).permit(:mode, :summary_balance, :summary_minimum_payment)
      end

      def render_debt_response(debt, status: :ok)
        render json: { debt: serialize(debt.reload), debt_portfolio: HouseholdFinance::DebtPortfolio.new(current_household.reload).as_json }, status: status
      end

      def serialize(debt)
        {
          id: debt.id, label: debt.label, debt_type: debt.debt_type,
          balance: debt.balance_known? ? HouseholdFinance::Money.dollars(debt.balance_cents) : nil,
          minimum_payment: debt.minimum_payment_known? ? HouseholdFinance::Money.dollars(debt.minimum_payment_cents) : nil,
          interest_rate_percent: debt.interest_rate_percent&.to_f,
          active: debt.active?, archived_at: debt.archived_at&.iso8601,
          source_type: debt.source_type, source_metadata: debt.source_metadata
        }
      end
    end
  end
end
