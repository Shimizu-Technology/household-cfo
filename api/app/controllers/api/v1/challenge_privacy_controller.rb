module Api
  module V1
    class ChallengePrivacyController < BaseController
      wrap_parameters false
      before_action :authenticate_user!
      before_action :disable_caching!

      ACTIONS = {
        "consent" => "privacy.consent.set", "support_request" => "support.request.create",
        "support_grant" => "support.access.grant", "support_revoke" => "support.access.revoke",
        "source_authorize" => "source_use.authorize", "source_revoke" => "source_use.revoke"
      }.freeze
      rescue_from ArgumentError, ActiveRecord::RecordInvalid do |error|
        render json: { errors: [ error.message ] }, status: :unprocessable_entity
      end
      rescue_from ChallengePrivacy::Access::Denied, SavingsChallenge::AccessPolicy::Unavailable do |error|
        render json: { errors: [ error.message ] }, status: :forbidden
      end
      rescue_from ActiveRecord::RecordNotFound do
        render json: { errors: [ "Private record not found" ] }, status: :not_found
      end
      rescue_from HouseholdFinance::Operations::Base::StaleOperation, HouseholdFinance::Operations::Runner::IdempotencyConflict do |error|
        render json: { errors: [ error.message ] }, status: :conflict
      end

      def show
        render json: private_read {
          reflections = reflection_page
          { enrollment_id: enrollment.id, actor_scope: { user_id: current_user.id, household_id: current_household.id },
            policy_version: "challenge_privacy_v1",
            grants: ChallengePrivacyGrant.where(savings_enrollment: enrollment).order(:id).map { |grant| grant.attributes.slice("id", "kind", "recipient_user_id", "granted", "selected_records", "expires_at", "policy_version", "lock_version") },
            support_requests: ChallengeSupportTicket.where(savings_enrollment: enrollment).order(:id).map { |ticket| ticket.attributes.slice("id", "recipient_user_id", "issue_kind", "message", "selected_records", "status", "lock_version", "created_at") },
            support_access: ChallengeSupportAccess.where(savings_enrollment: enrollment).order(:id).map { |access| access.attributes.slice("id", "challenge_support_ticket_id", "recipient_user_id", "selected_records", "reason", "expires_at", "revoked_at", "lock_version") },
            erasable_reflections: reflections[:records], reflections_next_cursor: reflections[:next_cursor],
            recipients: recipients,
            downloaded_copies_retrievable: false }
        }
      end

      def selection_candidates
        result = private_read do
          ChallengePrivacy::Access.participant!(current_household, current_user, enrollment, active: true)
          type = params[:record_type].to_s
          scope = case type
          when "document_source" then current_household.financial_document_imports
          when "source_review_version" then SourceReviewVersion.where(household: current_household)
          when "savings_entry_version" then enrollment.savings_entry_versions
          when "savings_plan_version" then enrollment.savings_plan_versions
          when "chat_message" then ChatMessage.joins(:chat_session).where(chat_sessions: { household_id: current_household.id, user_id: current_user.id })
          else raise ArgumentError, "Choose a supported exact record type"
          end
          scope = scope.where("#{scope.table_name}.id > ?", SavingsChallenge::Inputs.id!(params[:cursor])) if params[:cursor].present?
          rows = scope.order("#{scope.table_name}.id").limit(51).to_a
          records = rows.first(50).filter_map do |record|
            next if type == "document_source" && !record.source_available?
            { record_type: type, record_id: record.id, preview: selection_preview(type, record), shares_entire_record: true }
          end
          { records: records, next_cursor: rows.length > 50 ? rows[49].id : nil, actor_scope: { user_id: current_user.id, household_id: current_household.id } }
        end
        render json: result
      end

      # Self-only control metadata remains reachable when program reads are held.
      # It grants no financial, chat or reflection-content read exception.
      def controls
        records = ApplicationRecord.transaction do
          current_household.lock!
          scope = SavingsEnrollment.where(household: current_household, user: current_user).order(:id)
          scope = scope.where("id > ?", SavingsChallenge::Inputs.id!(params[:cursor])) if params[:cursor].present?
          rows = scope.includes(:cohort).limit(51).to_a
          rows.each { |record| ChallengePrivacy::Access.participant!(current_household, current_user, record) }
          { records: rows.first(50).map { |record| record.attributes.slice("id", "cohort_id", "starts_on", "ends_on", "time_zone", "status").merge("program_name" => record.cohort.name) },
            next_cursor: rows.length > 50 ? rows[49].id : nil, actor_scope: { user_id: current_user.id, household_id: current_household.id } }
        end
        render json: records
      end

      def source_use
        render json: private_read {
          source = current_household.financial_document_imports.find(params[:document_import_id])
          description = ChallengePrivacy::SourceRetention.new(current_household, user: current_user).describe(source)
          use = FinancialSourceUse.find_by(financial_document_import: source, savings_enrollment: enrollment)
          description.merge(expected_affected_uses_digest: HouseholdFinance::Operations::PreparedOperation.fingerprint(description[:affected_uses]),
            disclosure_version: ChallengePrivacy::SourceRetention::DISCLOSURE_VERSION,
            expected_expires_at: (enrollment.ends_on.in_time_zone(enrollment.time_zone).end_of_day + 30.days).iso8601,
            expected_use_id: use&.id, expected_lock_version: use&.lock_version || 0)
        }
      end

      def request_status
        result = private_read do
          key = ACTIONS.fetch(params[:privacy_action].to_s) { raise ArgumentError, "Choose a supported privacy action" }
          token = request.headers["Idempotency-Key"].to_s.strip
          raise ArgumentError, "Idempotency-Key is required" if token.empty?
          resolved = HouseholdFinance::Operations::Runner.new(current_household, user: current_user).private_request_result(operation_key: key, idempotency_key: token)
          if resolved
            raise ActiveRecord::RecordNotFound unless resolved.subject.savings_enrollment_id == enrollment.id
            { state: "committed", event: resolved.subject.attributes.slice("id", "action", "subject_type", "subject_id"), replayed: true }
          else
            { state: "unknown", can_retry: true }
          end
        end
        render json: result.merge(actor_scope: { user_id: current_user.id, household_id: current_household.id })
      rescue ActiveRecord::LockWaitTimeout
        render json: { state: "in_flight" }, status: :accepted
      end

      ACTIONS.each do |action, key|
        define_method(action) do
          input = request.request_parameters.to_h.deep_symbolize_keys
          raise ArgumentError, "Choose this enrollment's reviewed request" unless input[:enrollment_id].to_s == params[:enrollment_id].to_s
          private_read do
            request_key = request.headers["Idempotency-Key"].to_s.strip
            raise ArgumentError, "Idempotency-Key is required" if request_key.empty?
            result = HouseholdFinance::Operations::Runner.new(current_household, user: current_user).run(operation_key: key, input: input, idempotency_key: request_key)
            render json: { event: { id: result.subject.id, action: result.subject.action, subject_type: result.subject.subject_type,
              subject_id: result.subject.subject_id }, replayed: result.replayed? }
          end
        end
      end

      private

      def selection_preview(type, record)
        case type
        when "document_source" then { filename: record.filename, created_at: record.created_at }
        when "source_review_version" then record.attributes.slice("merchant", "posted_on", "signed_amount_cents", "event_type", "version_number")
        when "savings_entry_version" then record.attributes.slice("signed_cents", "effective_on", "version_number")
        when "savings_plan_version" then record.attributes.slice("target_cents", "version_number", "approved_at")
        when "chat_message" then { role: record.role, content_excerpt: record.content.truncate(500), created_at: record.created_at, excerpt_only: record.content.length > 500 }
        end
      end

      def reflection_page
        scope = SavingsDailyReflection.where(savings_enrollment: enrollment).order(:id)
        scope = scope.where("id > ?", SavingsChallenge::Inputs.id!(params[:reflections_cursor])) if params[:reflections_cursor].present?
        rows = scope.includes(:current_version).limit(51).to_a
        { records: rows.first(50).map { |reflection| reflection.attributes.slice("id", "current_version_id", "lock_version", "created_at").merge("erased_at" => reflection.current_version&.erased_at) },
          next_cursor: rows.length > 50 ? rows[49].id : nil }
      end

      def disable_caching! = response.set_header("Cache-Control", "private, no-store")
      def enrollment = @enrollment ||= SavingsEnrollment.where(household: current_household, user: current_user).find(params[:enrollment_id])
      def private_read
        ApplicationRecord.transaction do
          ApplicationRecord.connection.execute("SET LOCAL lock_timeout = '2s'") if action_name == "request_status"
          current_household.lock!
          enrollment.reload
          ChallengePrivacy::Access.participant!(current_household, current_user, enrollment)
          yield
        end
      end

      def recipients
        cohort = enrollment.cohort
        ids = cohort.cohort_memberships.where(role: %w[coach admin]).pluck(:user_id) + [ cohort.created_by_user_id ]
        workspace_ids = CoachWorkspaceMembership.where(coach_workspace_id: cohort.coach_workspace_id).select(:user_id)
        User.where(id: ids.compact & workspace_ids.pluck(:user_id), role: %w[coach admin]).where.not(invitation_status: "revoked").order(:id)
          .map { |user| { id: user.id, name: user.full_name.presence || user.email, role: user.role } }
      end
    end
  end
end
