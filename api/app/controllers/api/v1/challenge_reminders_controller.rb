module Api
  module V1
    class ChallengeRemindersController < BaseController
      wrap_parameters false
      before_action :authenticate_user!
      before_action { response.set_header("Cache-Control", "private, no-store") }
      ACTIONS = { "preference" => "reminder.preference.set", "dismiss" => "reminder.dismiss" }.freeze

      rescue_from ArgumentError, ActiveRecord::RecordInvalid do |error|
        render json: { errors: [ error.message ] }, status: :unprocessable_entity
      end
      rescue_from ActiveRecord::RecordNotFound do
        render json: { errors: [ "Private reminder not found" ] }, status: :not_found
      end
      rescue_from HouseholdFinance::Operations::Base::StaleOperation, HouseholdFinance::Operations::Runner::IdempotencyConflict do |error|
        render json: { errors: [ error.message ] }, status: :conflict
      end
      rescue_from ChallengePrivacy::Access::Denied, SavingsChallenge::AccessPolicy::Unavailable do |error|
        render json: { errors: [ error.message ] }, status: :forbidden
      end

      def show
        render json: domain.read(enrollment.id).merge(actor_scope: actor_scope)
      end

      def mutate
        input = request.request_parameters.to_h.deep_symbolize_keys
        raise ArgumentError, "Review this enrollment's reminder" unless input[:enrollment_id] == enrollment.id
        private_read do
          result = runner.run(operation_key: operation_key, input: input, idempotency_key: request_key)
          render json: { event: present(result.subject), replayed: result.replayed?, actor_scope: actor_scope }
        end
      end

      def request_status
        result = private_read do
          resolved = runner.private_request_result(operation_key: operation_key, idempotency_key: request_key)
          if resolved
            raise ActiveRecord::RecordNotFound unless resolved.subject.savings_enrollment_id == enrollment.id
            { state: "committed", event: present(resolved.subject), replayed: true }
          else
            { state: "unknown", can_retry: true }
          end
        end
        render json: result.merge(actor_scope: actor_scope)
      rescue ActiveRecord::LockWaitTimeout
        render json: { state: "in_flight", actor_scope: actor_scope }, status: :accepted
      end

      private
      def domain = ChallengeReminders::Domain.new(current_household, user: current_user)
      def enrollment = @enrollment ||= SavingsEnrollment.where(household: current_household, user: current_user).find(params[:enrollment_id])
      def actor_scope = { user_id: current_user.id, household_id: current_household.id }
      def runner = HouseholdFinance::Operations::Runner.new(current_household, user: current_user)
      def present(event) = event.attributes.slice("id", "action", "subject_type", "subject_id")
      def operation_key = ACTIONS.fetch(params[:reminder_action].to_s) { raise ArgumentError, "Choose a supported reminder action" }
      def request_key
        value = request.headers["Idempotency-Key"].to_s.strip
        raise ArgumentError, "Idempotency-Key is required" if value.empty?
        value
      end
      def private_read
        ApplicationRecord.transaction do
          ApplicationRecord.connection.execute("SET LOCAL lock_timeout = '2s'") if action_name == "request_status"
          current_household.lock!
          enrollment.reload
          domain.authorize!(enrollment)
          yield
        end
      end
    end
  end
end
