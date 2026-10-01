module Api
  module V1
    class GoalsController < BaseController
      before_action :authenticate_user!
      before_action :require_writable_household!

      def create
        result = runner.run(operation_key: "goal.record.create", input: goal_params.to_h.merge(source_type: "manual_ui"), idempotency_key: required_idempotency_key)
        render_goal_response(result.subject, status: :created)
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      rescue ActiveRecord::RecordNotUnique
        render json: { errors: [ "An active goal already uses that name and type" ] }, status: :unprocessable_entity
      rescue ArgumentError => e
        render_operation_error(e)
      end

      def update
        result = runner.run(operation_key: "goal.record.update", input: goal_params.to_h.merge(goal_id: scoped_goal.id), idempotency_key: required_idempotency_key)
        render_goal_response(result.subject)
      rescue ActiveRecord::RecordNotFound
        render json: { errors: [ "Goal not found" ] }, status: :not_found
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      rescue ActiveRecord::RecordNotUnique
        render json: { errors: [ "An active goal already uses that name and type" ] }, status: :unprocessable_entity
      rescue ArgumentError => e
        render_operation_error(e)
      end

      def destroy
        result = run_for_goal("goal.record.archive")
        render_goal_response(result.subject)
      rescue ActiveRecord::RecordNotFound
        render json: { errors: [ "Goal not found" ] }, status: :not_found
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      rescue ArgumentError => e
        render_operation_error(e)
      end

      def restore
        result = run_for_goal("goal.record.restore")
        render_goal_response(result.subject)
      rescue ActiveRecord::RecordNotFound
        render json: { errors: [ "Goal not found" ] }, status: :not_found
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      rescue ActiveRecord::RecordNotUnique
        render json: { errors: [ "An active goal already uses that name and type" ] }, status: :unprocessable_entity
      rescue ArgumentError => e
        render_operation_error(e)
      end

      private

      def runner
        @runner ||= HouseholdFinance::Operations::Runner.new(current_household, user: current_user)
      end

      def run_for_goal(key)
        runner.run(operation_key: key, input: { goal_id: scoped_goal.id }, idempotency_key: required_idempotency_key)
      end

      def required_idempotency_key
        request.headers["Idempotency-Key"].to_s.strip.presence || raise(ArgumentError, "Idempotency-Key header is required")
      end

      def scoped_goal
        @scoped_goal ||= current_household.goals.tracked.find(params[:id])
      end

      def goal_params
        params.fetch(:goal, {}).permit(:label, :goal_type, :target_amount, :current_amount, :target_on)
      end

      def render_goal_response(goal, status: :ok)
        presenter = HouseholdFinance::DataPresenter.new(current_household.reload, user: current_user)
        render json: { goal: presenter.goal_records.find { |row| row.fetch(:id) == goal.id }, goal_portfolio: HouseholdFinance::GoalPortfolio.new(current_household).as_json }, status: status
      end
    end
  end
end
