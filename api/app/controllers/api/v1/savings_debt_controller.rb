module Api
  module V1
    class SavingsDebtController < BaseController
      wrap_parameters false
      before_action :authenticate_user!
      around_action :private_request
      ACTIONS = { "stage" => "savings.debt.stage", "approve" => "savings.debt.approve" }.freeze
      rescue_from ArgumentError, ActiveRecord::RecordInvalid do |error|
        render json: { errors: [ error.message ] }, status: :unprocessable_entity
      end
      rescue_from HouseholdFinance::Operations::Base::StaleOperation, HouseholdFinance::Operations::Runner::IdempotencyConflict do |error|
        render json: { errors: [ error.message ] }, status: :conflict
      end
      rescue_from ActiveRecord::RecordNotFound do
        render json: { errors: [ "Private card review not found" ] }, status: :not_found
      end
      rescue_from SavingsChallenge::AccessPolicy::Unavailable do |error|
        render json: { errors: [ error.message ] }, status: :forbidden
      end

      def show = render json: reader.call
      def records = render json: reader.records(kind: params[:kind].to_s, cursor: params[:cursor])
      def source_candidates = render json: reader.candidates(cursor: params[:cursor])

      def mutate
        input = request.request_parameters.to_h.deep_symbolize_keys
        raise ArgumentError, "Card request contains unsupported fields" if input.key?(:cohort_id)
        result = runner.run(operation_key: operation_key, input: input.merge(cohort_id: @enrollment.cohort_id), idempotency_key: request_key)
        render json: { record: SavingsChallenge::Debt::Reader.record(result.subject), replayed: result.replayed?, actor_scope: actor_scope, enrollment_id: @enrollment&.id, cohort_id: current_cohort_membership&.cohort_id }
      end

      def request_status
        result = runner.private_request_result(operation_key: operation_key, idempotency_key: request_key)
        if result
          raise ActiveRecord::RecordNotFound unless result.subject.savings_enrollment_id == @enrollment.id
          render json: { state: "committed", record: SavingsChallenge::Debt::Reader.record(result.subject), replayed: true, actor_scope: actor_scope, enrollment_id: @enrollment&.id, cohort_id: current_cohort_membership&.cohort_id }
        else
          render json: { state: "unknown", can_retry: true, actor_scope: actor_scope, enrollment_id: @enrollment&.id, cohort_id: current_cohort_membership&.cohort_id }
        end
      end

      private

      def private_request
        response.set_header("Cache-Control", "private, no-store")
        ApplicationRecord.transaction do
          ApplicationRecord.connection.execute("SET LOCAL lock_timeout = '2s'") if action_name == "request_status"
          current_household.lock!
          membership = current_cohort_membership
          raise SavingsChallenge::AccessPolicy::Unavailable, "Select your current savings program" unless membership
          @enrollment = SavingsEnrollment.find_by!(household: current_household, user: current_user, cohort_id: membership.cohort_id)
          SavingsChallenge::Debt::Reader.authorize!(@enrollment, user: current_user)
          yield
          SavingsChallenge::Debt::Reader.authorize!(@enrollment, user: current_user)
        end
      rescue ActiveRecord::LockWaitTimeout
        raise unless action_name == "request_status"
        render json: { state: "in_flight", actor_scope: actor_scope, enrollment_id: @enrollment&.id, cohort_id: current_cohort_membership&.cohort_id }, status: :accepted
      end

      def actor_scope = { user_id: current_user.id, household_id: current_household.id }
      def reader = SavingsChallenge::Debt::Reader.new(@enrollment, user: current_user)
      def runner = HouseholdFinance::Operations::Runner.new(current_household, user: current_user)
      def operation_key = ACTIONS.fetch(params[:review_action].to_s) { raise ArgumentError, "Choose stage or approve" }
      def request_key
        key = request.headers["Idempotency-Key"].to_s.strip
        raise ArgumentError, "Idempotency-Key is required" if key.empty?
        key
      end
    end
  end
end
