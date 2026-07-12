module Api
  module V1
    class IncomeScheduleEntriesController < BaseController
      before_action :authenticate_user!

      def create
        entry = current_income_source.income_schedule_entries.create!(normalized_entry_attributes)
        render_budget(entry, status: :created)
      rescue ActiveRecord::RecordNotFound
        render json: { errors: [ "Income source not found" ] }, status: :not_found
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      rescue ActiveRecord::RecordNotUnique
        render json: { errors: [ "A recurring income change already exists for that month" ] }, status: :unprocessable_entity
      rescue ArgumentError => e
        render json: { errors: [ e.message ] }, status: :unprocessable_entity
      end

      def update
        entry = current_entry
        entry.update!(normalized_entry_attributes)
        render_budget(entry)
      rescue ActiveRecord::RecordNotFound
        render json: { errors: [ "Income schedule entry not found" ] }, status: :not_found
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      rescue ActiveRecord::RecordNotUnique
        render json: { errors: [ "A recurring income change already exists for that month" ] }, status: :unprocessable_entity
      rescue ArgumentError => e
        render json: { errors: [ e.message ] }, status: :unprocessable_entity
      end

      def destroy
        entry = current_entry
        entry.destroy!
        render_budget(entry)
      rescue ActiveRecord::RecordNotFound
        render json: { errors: [ "Income schedule entry not found" ] }, status: :not_found
      end

      private

      def current_income_source
        @current_income_source ||= current_household.income_sources.where(active: true).find(entry_params[:income_source_id])
      end

      def current_entry
        @current_entry ||= IncomeScheduleEntry
          .joins(:income_source)
          .where(income_sources: { household_id: current_household.id })
          .find(params[:id])
      end

      def entry_params
        params.require(:income_schedule_entry).permit(:income_source_id, :entry_type, :label, :amount, :cadence, :effective_on)
      end

      def normalized_entry_attributes
        type = entry_params[:entry_type].presence || "recurring_change"
        date = Date.iso8601(entry_params.require(:effective_on).to_s).beginning_of_month
        raise ArgumentError, "Income schedule date is outside the supported range" unless HouseholdFinance::AnnualBudgetManager.supported_year?(date.year)

        {
          entry_type: type,
          label: entry_params[:label].to_s.squish.presence,
          amount_cents: HouseholdFinance::Money.cents!(entry_params[:amount], message: "Income amount must be a number"),
          cadence: type == "one_time" ? "one_time" : entry_params[:cadence].presence || "monthly",
          effective_on: date
        }
      rescue Date::Error
        raise ArgumentError, "Income schedule date must be a valid date"
      end

      def render_budget(entry, status: :ok)
        manager = HouseholdFinance::AnnualBudgetManager.new(current_household.reload, year: budget_year_param(entry))
        render json: {
          income_schedule_entry: serialize_entry(entry),
          budget: HouseholdFinance::DataPresenter.new(current_household, user: current_user, annual_plan: manager.plan_data).budget
        }, status: status
      end

      def budget_year_param(entry)
        requested = params[:year].presence&.to_i
        return requested if requested && HouseholdFinance::AnnualBudgetManager.supported_year?(requested)

        entry.effective_on.year
      end

      def serialize_entry(entry)
        return { id: entry.id, deleted: true } if entry.destroyed?

        {
          id: entry.id,
          income_source_id: entry.income_source_id,
          entry_type: entry.entry_type,
          label: entry.label,
          amount: HouseholdFinance::Money.dollars(entry.amount_cents),
          cadence: entry.cadence,
          effective_on: entry.effective_on.iso8601
        }
      end
    end
  end
end
