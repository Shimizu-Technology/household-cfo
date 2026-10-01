module Api
  module V1
    class IncomeScheduleEntriesController < BaseController
      before_action :authenticate_user!
      before_action :require_writable_household!

      def create
        result = runner.run(
          operation_key: "income.schedule.create",
          input: entry_params.to_h.merge(source_id: current_income_source.id, year: operation_year),
          idempotency_key: required_idempotency_key
        )
        render_budget(entry_payload_from_result(result), year: operation_year, status: :created)
      rescue ActiveRecord::RecordNotFound
        render json: { errors: [ "Income source not found" ] }, status: :not_found
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      rescue ActiveRecord::RecordNotUnique
        render json: { errors: [ "A recurring income change already exists for that month" ] }, status: :unprocessable_entity
      rescue ArgumentError => e
        render_operation_error(e)
      end

      def update
        existing = existing_schedule_execution("income.schedule.update")
        entry = current_entry unless existing
        source_id = existing&.normalized_input&.fetch("source_id", nil)&.to_i || entry.income_source_id
        result = runner.run(
          operation_key: "income.schedule.update",
          input: entry_params.to_h.merge(source_id: source_id, entry_id: params[:id].to_i, year: operation_year),
          idempotency_key: required_idempotency_key
        )
        render_budget(entry_payload_from_result(result), year: operation_year)
      rescue ActiveRecord::RecordNotFound
        render json: { errors: [ "Income schedule entry not found" ] }, status: :not_found
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      rescue ActiveRecord::RecordNotUnique
        render json: { errors: [ "A recurring income change already exists for that month" ] }, status: :unprocessable_entity
      rescue ArgumentError => e
        render_operation_error(e)
      end

      def destroy
        existing = existing_delete_execution
        entry = current_entry unless existing
        entry_id = params[:id].to_i
        year = requested_budget_year || existing&.normalized_input&.fetch("year", nil)&.to_i || entry.effective_on.year
        source_id = existing&.normalized_input&.fetch("source_id", nil)&.to_i || entry.income_source_id
        runner.run(
          operation_key: "income.schedule.delete",
          input: { source_id: source_id, entry_id: entry_id, year: year },
          idempotency_key: required_idempotency_key
        )
        render_budget({ id: entry_id, deleted: true }, year: year)
      rescue ActiveRecord::RecordNotFound
        render json: { errors: [ "Income schedule entry not found" ] }, status: :not_found
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

      def existing_delete_execution
        existing_schedule_execution("income.schedule.delete")
      end

      def existing_schedule_execution(operation_key)
        key = request.headers["Idempotency-Key"].to_s.strip
        return if key.blank?
        execution = current_household.household_operation_executions.find_by(idempotency_key: key, operation_key: operation_key)
        execution if execution&.normalized_input&.fetch("entry_id", nil).to_i == params[:id].to_i
      end

      def current_income_source
        @current_income_source ||= current_household.income_sources.find(entry_params[:income_source_id])
      end

      def current_entry
        @current_entry ||= IncomeScheduleEntry.joins(:income_source)
          .where(income_sources: { household_id: current_household.id })
          .find(params[:id])
      end

      def entry_params
        params.require(:income_schedule_entry).permit(:income_source_id, :entry_type, :label, :amount, :cadence, :effective_on, :retained_after_transition)
      end

      def operation_year
        requested_budget_year || Date.iso8601(entry_params.require(:effective_on).to_s).year
      rescue Date::Error
        Date.current.year
      end

      def requested_budget_year
        value = params[:year].presence&.to_i
        value if value && HouseholdFinance::AnnualBudgetManager.supported_year?(value)
      end

      def render_budget(entry_payload, year:, status: :ok)
        manager = HouseholdFinance::AnnualBudgetManager.new(current_household.reload, year: year)
        render json: {
          income_schedule_entry: entry_payload,
          budget: current_data_presenter(annual_plan: manager.plan_data).budget
        }, status: status
      end

      def entry_payload_from_result(result)
        input = result.execution.normalized_input
        entry_id = input["entry_id"].to_i
        entries = Array(result.after_snapshot["schedule_entries"])
        if entry_id.zero?
          before_ids = Array(result.execution.before_snapshot["schedule_entries"]).map { |entry| entry["id"].to_i }
          entry_id = entries
            .map { |entry| entry["id"].to_i }
            .find { |id| id.positive? && !before_ids.include?(id) }
        end
        entry = entries.find { |candidate| candidate["id"].to_i == entry_id }
        raise ActiveRecord::RecordNotFound, "Income schedule entry not found" unless entry

        {
          id: entry.fetch("id"), income_source_id: entry.fetch("income_source_id"), entry_type: entry.fetch("entry_type"),
          label: entry["label"], amount: HouseholdFinance::Money.dollars(entry.fetch("amount_cents")), cadence: entry.fetch("cadence"),
          effective_on: entry.fetch("effective_on"), retained_after_transition: ActiveModel::Type::Boolean.new.cast(entry["retained_after_transition"])
        }
      end
    end
  end
end
