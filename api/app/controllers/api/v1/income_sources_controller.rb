module Api
  module V1
    class IncomeSourcesController < BaseController
      before_action :authenticate_user!
      before_action :require_writable_household!

      def create
        result = runner.run(operation_key: "income.source.create", input: source_params.to_h.merge(year: budget_year_param), idempotency_key: required_idempotency_key)
        render_source_response(result.subject, status: :created)
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      rescue ActiveRecord::RecordNotUnique
        render json: { errors: [ "An income source with that name and type already exists" ] }, status: :unprocessable_entity
      rescue ArgumentError => e
        render_operation_error(e)
      end

      def update
        result = runner.run(operation_key: "income.source.update", input: source_params.to_h.merge(source_id: scoped_source.id, year: budget_year_param), idempotency_key: required_idempotency_key)
        render_source_response(result.subject)
      rescue ActiveRecord::RecordNotFound
        render json: { errors: [ "Income source not found" ] }, status: :not_found
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      rescue ActiveRecord::RecordNotUnique
        render json: { errors: [ "An income source with that name and type already exists" ] }, status: :unprocessable_entity
      rescue ArgumentError => e
        render_operation_error(e)
      end

      def destroy
        result = runner.run(
          operation_key: "income.source.archive",
          input: { source_id: scoped_source.id, ends_on: source_params[:ends_on].presence || Date.current.iso8601, year: budget_year_param },
          idempotency_key: required_idempotency_key
        )
        render_source_response(result.subject)
      rescue ActiveRecord::RecordNotFound
        render json: { errors: [ "Income source not found" ] }, status: :not_found
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      rescue ArgumentError => e
        render_operation_error(e)
      end

      def restore
        result = runner.run(operation_key: "income.source.restore", input: { source_id: scoped_source.id, year: budget_year_param }, idempotency_key: required_idempotency_key)
        render_source_response(result.subject)
      rescue ActiveRecord::RecordNotFound
        render json: { errors: [ "Income source not found" ] }, status: :not_found
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

      def scoped_source
        @scoped_source ||= current_household.income_sources.find(params[:id])
      end

      def source_params
        params.fetch(:income_source, {}).permit(:label, :source_type, :amount, :cadence, :starts_on, :ends_on)
      end

      def budget_year_param
        requested = params[:year].presence&.to_i
        return requested if requested && HouseholdFinance::AnnualBudgetManager.supported_year?(requested)
        Date.current.year
      end

      def render_source_response(source, status: :ok)
        manager = HouseholdFinance::AnnualBudgetManager.new(current_household.reload, year: budget_year_param)
        render json: { income_source: serialize_source(source.reload), budget: current_data_presenter(annual_plan: manager.plan_data).budget }, status: status
      end

      def serialize_source(source)
        {
          id: source.id, label: source.label, source_type: source.source_type,
          base_amount: HouseholdFinance::Money.dollars(source.amount_cents), base_cadence: source.cadence,
          active: source.effective_on?(Date.current), starts_on: source.starts_on&.iso8601, ends_on: source.ends_on&.iso8601
        }
      end
    end
  end
end
