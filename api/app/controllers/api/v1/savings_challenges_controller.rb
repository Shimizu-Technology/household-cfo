module Api
  module V1
    class SavingsChallengesController < BaseController
      wrap_parameters false
      before_action :authenticate_user!
      before_action :require_savings_access!
      around_action :private_request

      REQUEST_ACTIONS = { "enrollment" => "savings.enrollment.accept", "plan_stage" => "savings.plan.stage",
        "plan_approve" => "savings.plan.approve", "entry_stage" => "savings.entry.stage", "entry_approve" => "savings.entry.approve",
        "zero_attest" => "savings.zero.attest" }.freeze

      rescue_from ArgumentError do |error|
        render json: { errors: [ error.message ], code: "savings_input_invalid" }, status: :unprocessable_entity
      end
      rescue_from SavingsChallenge::AccessPolicy::Unavailable do |error|
        render json: { errors: [ error.message ], code: "savings_challenge_unavailable" }, status: :forbidden
      end
      rescue_from ActiveRecord::RecordNotFound do
        render json: { errors: [ "Savings record not found" ] }, status: :not_found
      end
      rescue_from HouseholdFinance::Operations::Base::StaleOperation, HouseholdFinance::Operations::Runner::IdempotencyConflict do |error|
        render json: { errors: [ error.message ], code: "savings_review_conflict" }, status: :conflict
      end
      rescue_from ActiveRecord::RecordInvalid do |error|
        render json: { errors: error.record.errors.full_messages }, status: :unprocessable_entity
      end

      def show
        render json: challenge_data
      end

      def request_status
        operation = REQUEST_ACTIONS.fetch(params[:review_action].to_s) { raise ArgumentError, "Choose a supported savings request" }
        key = request.headers["Idempotency-Key"].to_s.strip
        raise ArgumentError, "Idempotency-Key header is required" if key.empty?
        resolved = HouseholdFinance::Operations::Runner.new(current_household, user: current_user).private_request_result(operation_key: operation, idempotency_key: key)
        result = if resolved
          subject = resolved.subject
          enrollment = subject.is_a?(SavingsEnrollment) ? subject : subject.savings_enrollment
          raise ActiveRecord::RecordNotFound unless enrollment.id == enrollment!.id
          { state: "committed", record: SavingsChallenge::ParticipantSerializer.record(subject), replayed: true, challenge: challenge_data }
        else
          { state: "unknown", can_retry: true }
        end
        render json: result.merge(actor_scope: { user_id: current_user.id, household_id: current_household.id }, cohort_id: @savings_cohort.id)
      end

      def enroll
        mutate("savings.enrollment.accept", %i[participation_accepted policy_version late_start_accepted expected_acceptance_digest])
      end

      def stage_plan
        mutate("savings.plan.stage", %i[target_cents expected_plan_version_id reason financial_baseline_version_id baseline_digest spending_changes])
      end

      def approve_plan
        mutate("savings.plan.approve", %i[accepted expected_draft_lock_version expected_plan_version_id], draft_id: path_id)
      end

      def stage_entry
        mutate("savings.entry.stage", %i[signed_cents effective_on funding_source expected_version_id entry_id expected_entry_lock_version reason])
      end

      def approve_entry
        mutate("savings.entry.approve", %i[accepted expected_draft_lock_version expected_version_id expected_entry_lock_version], draft_id: path_id)
      end

      def attest_zero
        mutate("savings.zero.attest", %i[known_zero cutoff_on expected_enrollment_lock_version])
      end

      def entries
        page!(enrollment!.savings_entries.includes(:current_approved_version))
      end

      def entry_versions
        page!(enrollment!.savings_entry_versions)
      end

      def entry_drafts
        scope = SavingsEntryDraft.joins(:savings_entry).where(savings_entries: { savings_enrollment_id: enrollment!.id })
        page!(scope)
      end

      def plan_versions
        page!(enrollment!.savings_plan_versions)
      end

      def plan_drafts
        page!(enrollment!.savings_plan_drafts)
      end

      def zero_attestations
        page!(enrollment!.savings_zero_attestations)
      end

      private

      def private_request
        response.set_header("Cache-Control", "private, no-store")
        ApplicationRecord.transaction do
          ApplicationRecord.connection.execute("SET LOCAL lock_timeout = '2s'") if action_name == "request_status"
          current_household.lock!
          require_savings_access!
          yield
        end
      rescue ActiveRecord::LockWaitTimeout
        raise unless action_name == "request_status"
        render json: { state: "in_flight", cohort_id: @savings_cohort.id, actor_scope: { user_id: current_user.id, household_id: current_household.id } }, status: :accepted
      end

      def require_savings_access!
        raise SavingsChallenge::AccessPolicy::Unavailable, "Select an available savings challenge" unless current_cohort_membership
        @savings_cohort = current_cohort_membership.cohort
        @savings_enrollment = SavingsEnrollment.find_by(household_id: current_household.id, user_id: current_user.id, cohort_id: @savings_cohort.id)
        SavingsChallenge::AccessPolicy.new(household: current_household, user: current_user, cohort: @savings_cohort, enrollment: @savings_enrollment).call!
      end

      def enrollment!
        @savings_enrollment || raise(ActiveRecord::RecordNotFound)
      end

      def path_id
        SavingsChallenge::Inputs.id!(params[:id])
      end

      def mutate(operation_key, fields, **server_fields)
        input = request.request_parameters.to_h.deep_symbolize_keys
        raise ArgumentError, "Savings request contains unsupported fields" unless (input.keys - fields).empty?
        key = request.headers["Idempotency-Key"].to_s.strip
        raise ArgumentError, "Idempotency-Key header is required" if key.empty?
        result = HouseholdFinance::Operations::Runner.new(current_household, user: current_user).run(
          operation_key: operation_key, input: input.merge(cohort_id: @savings_cohort.id, **server_fields), idempotency_key: key
        )
        @savings_enrollment = SavingsEnrollment.find_by!(household_id: current_household.id, user_id: current_user.id, cohort_id: @savings_cohort.id)
        render json: { record: SavingsChallenge::ParticipantSerializer.record(result.subject), replayed: result.replayed?, challenge: challenge_data }
      end

      def challenge_data
        return { cohort_id: @savings_cohort.id, enrollment: nil, accepted_plan: nil, projection: nil, suggested_target_cents: 50_000, offer: enrollment_offer } unless @savings_enrollment
        enrollment = @savings_enrollment.reload
        {
          cohort_id: @savings_cohort.id, enrollment: SavingsChallenge::ParticipantSerializer.record(enrollment),
          accepted_plan: enrollment.current_accepted_plan_version && SavingsChallenge::ParticipantSerializer.record(enrollment.current_accepted_plan_version),
          projection: SavingsChallenge::Projection.new(enrollment).call,
          calendar: SavingsChallenge::ParticipantSerializer.calendar(enrollment),
          pending_entry_count: SavingsEntryDraft.joins(:savings_entry).where(savings_entries: { savings_enrollment_id: enrollment.id }, status: "pending").count,
          pending_plan_count: enrollment.savings_plan_drafts.where(status: "pending").count
        }
      end

      def enrollment_offer
        SavingsChallenge::EnrollmentOffer.call(cohort: @savings_cohort, user: current_user, membership: current_cohort_membership)
      end

      def page!(scope)
        cursor = params[:cursor].nil? ? 0 : SavingsChallenge::Inputs.id!(params[:cursor])
        limit = params[:limit].nil? ? 50 : SavingsChallenge::Inputs.id!(params[:limit])
        raise ArgumentError, "Page limit must be between 1 and 100" unless limit.between?(1, 100)
        rows = scope.where("#{scope.klass.table_name}.id > ?", cursor).order(:id).limit(limit + 1).to_a
        has_more = rows.length > limit
        visible = rows.first(limit)
        render json: { records: visible.map { |record| SavingsChallenge::ParticipantSerializer.record(record) }, next_cursor: has_more ? visible.last.id : nil,
          actor_scope: { user_id: current_user.id, household_id: current_household.id },
          enrollment_id: enrollment!.id, cohort_id: @savings_cohort.id }
      end
    end
  end
end
