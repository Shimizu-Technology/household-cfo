module Api
  module V1
    class SavingsChallengesController < BaseController
      wrap_parameters false
      before_action :authenticate_user!
      before_action :require_savings_access!, unless: :private_snapshot_read?
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
      rescue_from ActiveRecord::StaleObjectError do
        render json: { errors: [ "This card changed. Reopen Ask Mia before continuing." ] }, status: :conflict
      end
      rescue_from ActiveRecord::RecordInvalid do |error|
        render json: { errors: error.record.errors.full_messages }, status: :unprocessable_entity
      end

      def show
        render json: challenge_data
      end

      def chat_cards
        render json: { records: own_chat_cards.where(status: "pending").order(:id).map(&:as_api_json),
          actor_scope: { user_id: current_user.id, household_id: current_household.id },
          enrollment_id: enrollment!.id, cohort_id: @savings_cohort.id }
      end

      def update_chat_card
        card = own_chat_cards.lock.find(path_id)
        input = request.request_parameters.to_h.deep_symbolize_keys
        action = input[:action].to_s
        raise ArgumentError, "Choose a supported card action" unless %w[save_state dismiss approve_goal approve_savings].include?(action)
        if card.status == "closed"
          if action == "save_state" && input.dig(:state, :phase) != "saved"
            raise HouseholdFinance::Operations::Base::StaleOperation, "This check-in was finished or closed in another window. Reopen Ask Mia."
          end
          if action == "approve_goal" && (!card.state["approved_plan_version_id"] || card.state["approved_plan_version_id"] != enrollment!.current_accepted_plan_version_id)
            raise HouseholdFinance::Operations::Base::StaleOperation, "This goal was replaced or closed. Reopen Ask Mia to review the current goal."
          end
          if action == "approve_savings" && !card.state["approved"]
            raise HouseholdFinance::Operations::Base::StaleOperation, "This savings card was already reviewed. Open Savings to confirm or fix its record."
          end
          return render json: { record: card.as_api_json, challenge: action.in?(%w[approve_goal approve_savings]) ? challenge_data : nil }
        end
        raise HouseholdFinance::Operations::Base::StaleOperation, "This card changed in another window. Reopen Ask Mia before continuing." unless input[:expected_lock_version] == card.lock_version
        case action
        when "save_state"
          raise ArgumentError, "Only a check-in has save progress" unless card.kind == "daily_report" && input[:state].is_a?(Hash)
          if input[:state][:phase] == "saved"
            card.update!(status: "closed", state: {}, input: card.input.except("feelings"))
          else
            card.update!(state: input[:state])
          end
        when "dismiss"
          card.update!(status: "closed", state: {}, input: card.input.except("feelings"))
        when "approve_goal"
          raise ArgumentError, "Review and accept the goal" unless card.kind == "goal" && input[:accepted] == true
          values = card.input.except("weekly_cents").deep_symbolize_keys.merge(cohort_id: enrollment!.cohort_id)
          runner = HouseholdFinance::Operations::Runner.new(current_household, user: current_user)
          draft = runner.run(operation_key: "savings.plan.stage", input: values, idempotency_key: "chat-goal-stage-#{card.id}").subject
          approved = runner.run(operation_key: "savings.plan.approve",
            input: { cohort_id: enrollment!.cohort_id, draft_id: draft.id, accepted: true,
              expected_draft_lock_version: draft.lock_version, expected_plan_version_id: draft.base_plan_version_id },
            idempotency_key: "chat-goal-approve-#{card.id}").subject
          card.update!(status: "closed", state: { approved_plan_version_id: approved.id })
        when "approve_savings"
          approve_savings_card!(card, input)
        end
        render json: { record: card.as_api_json, challenge: action.in?(%w[approve_goal approve_savings]) ? challenge_data : nil }
      end

      # The same two steps Savings Home takes (stage, then approve), done from
      # the chat card once she says Yes. Every check on those operations still applies.
      def approve_savings_card!(card, input)
        raise ArgumentError, "Review and accept the amount" unless card.kind == "savings" && input[:accepted] == true

        intake = card.input.deep_symbolize_keys
        raise ArgumentError, "Choose a savings review card" unless intake[:kind].in?(%w[contribution withdrawal])
        raise ArgumentError, "Which day was this? Open Savings to choose the date." if intake[:date_required] || intake[:effective_on].blank?

        withdrawal = intake[:kind] == "withdrawal"
        correction = intake[:correction].presence&.deep_symbolize_keys
        if !withdrawal && !correction && input[:new_money_confirmed] != true
          raise ArgumentError, "Tick the box to confirm this was new money you set aside."
        end
        funding = if withdrawal then "withdrawal"
        elsif correction then correction.dig(:current_approved_version, :funding_source) || "new_money_reserved"
        else "new_money_reserved"
        end
        runner = HouseholdFinance::Operations::Runner.new(current_household, user: current_user)
        stage = { cohort_id: enrollment!.cohort_id, signed_cents: intake[:signed_cents] || (withdrawal ? -intake[:amount_cents] : intake[:amount_cents]),
          effective_on: intake[:effective_on], funding_source: funding, expected_version_id: correction&.dig(:current_approved_version_id),
          reason: intake[:reason].to_s }
        stage.merge!(entry_id: correction[:id], expected_entry_lock_version: correction[:lock_version]) if correction
        draft = runner.run(operation_key: "savings.entry.stage", input: stage, idempotency_key: "chat-savings-stage-#{card.id}").subject
        runner.run(operation_key: "savings.entry.approve", idempotency_key: "chat-savings-approve-#{card.id}",
          input: { cohort_id: enrollment!.cohort_id, draft_id: draft.id, accepted: true, expected_draft_lock_version: draft.lock_version,
                   expected_version_id: draft.base_version_id, expected_entry_lock_version: draft.base_entry_lock_version })
        card.update!(status: "closed", state: { entry_draft_id: draft.id, approved: true })
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
        mutate("savings.entry.stage", %i[signed_cents effective_on funding_source expected_version_id entry_id expected_entry_lock_version reason chat_card_id])
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

      # Optional status=pending|approved lets Home list what is waiting for the
      # participant separately from what they already confirmed.
      def entry_drafts
        scope = SavingsEntryDraft.joins(:savings_entry).includes(:savings_entry).where(savings_entries: { savings_enrollment_id: enrollment!.id })
        unless params[:status].nil?
          status = params[:status].to_s
          raise ArgumentError, "Draft status must be pending or approved" unless %w[pending approved].include?(status)
          scope = scope.where(status: status)
        end
        page!(scope)
      end

      def plan_versions
        page!(enrollment!.savings_plan_versions)
      end

      def plan_drafts
        page!(SavingsPlanDraft.visible_for(enrollment!))
      end

      def zero_attestations
        page!(enrollment!.savings_zero_attestations)
      end

      private

      def private_request
        response.set_header("Cache-Control", "private, no-store")
        if private_snapshot_read?
          return with_private_read_snapshot(authorize: :require_savings_access!) { yield }
        end

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
        @savings_enrollment = SavingsEnrollment.in_use.find_by(household_id: current_household.id, user_id: current_user.id, cohort_id: @savings_cohort.id)
        SavingsChallenge::AccessPolicy.new(household: current_household, user: current_user, cohort: @savings_cohort, enrollment: @savings_enrollment).call!
      end

      def own_chat_cards
        SavingsChatCard.where(savings_enrollment: enrollment!).for_picture(current_household.financial_generation)
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
        runner = HouseholdFinance::Operations::Runner.new(current_household, user: current_user)
        if operation_key == "savings.entry.stage" && input[:chat_card_id]
          card = own_chat_cards.find(input.delete(:chat_card_id))
          raise ArgumentError, "Choose a savings review card" unless card.kind == "savings"
          staged_id = card.state["entry_draft_id"]
          if card.status == "closed" && (staged_id.nil? || runner.private_request_result(operation_key: operation_key, idempotency_key: key)&.subject&.id != staged_id)
            raise HouseholdFinance::Operations::Base::StaleOperation, "This savings card was already reviewed. Open Savings to confirm or fix its record."
          end
          expected_entry = card.input.dig("correction", "id")
          raise ArgumentError, "Review the entry shown on the savings card" unless input[:entry_id] == expected_entry
        end
        result = runner.run(
          operation_key: operation_key, input: input.merge(cohort_id: @savings_cohort.id, **server_fields), idempotency_key: key
        )
        card&.update!(status: "closed", state: { entry_draft_id: result.subject.id })
        @savings_enrollment = SavingsEnrollment.in_use.find_by!(household_id: current_household.id, user_id: current_user.id, cohort_id: @savings_cohort.id)
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
          timeline: SavingsChallenge::Daily::Timeline.new(enrollment).call,
          pending_entry_count: SavingsEntryDraft.joins(:savings_entry).where(savings_entries: { savings_enrollment_id: enrollment.id }, status: "pending").count,
          pending_plan_count: SavingsPlanDraft.current_pending_id(enrollment) ? 1 : 0
        }
      end

      def enrollment_offer
        SavingsChallenge::EnrollmentOffer.call(cohort: @savings_cohort, user: current_user, membership: current_cohort_membership)
      end

      # Keyset pages over record ids.
      #   direction=oldest (default): ascending ids; `cursor` returns rows with a larger id.
      #   direction=newest: descending ids; `cursor` returns rows with a smaller id.
      # In both directions next_cursor is the id of the last row returned when more
      # rows remain in that direction, otherwise nil. Pass it back as `cursor`.
      def page!(scope)
        direction = params[:direction].nil? ? "oldest" : params[:direction].to_s
        raise ArgumentError, "Page direction must be oldest or newest" unless %w[oldest newest].include?(direction)
        cursor = params[:cursor].nil? ? nil : SavingsChallenge::Inputs.id!(params[:cursor])
        limit = params[:limit].nil? ? 50 : SavingsChallenge::Inputs.id!(params[:limit])
        raise ArgumentError, "Page limit must be between 1 and 100" unless limit.between?(1, 100)
        table = scope.klass.table_name
        rows = if direction == "newest"
          (cursor ? scope.where("#{table}.id < ?", cursor) : scope).reorder(id: :desc)
        else
          scope.where("#{table}.id > ?", cursor || 0).order(:id)
        end.limit(limit + 1).to_a
        has_more = rows.length > limit
        visible = rows.first(limit)
        render json: { records: SavingsChallenge::ParticipantSerializer.collection(visible, enrollment: enrollment!), next_cursor: has_more ? visible.last.id : nil,
          actor_scope: { user_id: current_user.id, household_id: current_household.id },
          enrollment_id: enrollment!.id, cohort_id: @savings_cohort.id }
      end
    end
  end
end
