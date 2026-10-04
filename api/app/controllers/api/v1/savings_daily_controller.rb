module Api
  module V1
    class SavingsDailyController < BaseController
      wrap_parameters false
      before_action :authenticate_user!
      before_action :disable_caching!
      before_action :require_challenge!, except: %i[erase_reflection erase_status]

      ACTIONS = {
        "purchase_stage" => "savings.daily.purchase.stage", "purchase_approve" => "savings.daily.purchase.approve",
        "reflection_save" => "savings.daily.reflection.save", "check_in_save" => "savings.daily.check_in.save",
        "checkpoint_stage" => "savings.checkpoint.stage", "checkpoint_approve" => "savings.checkpoint.approve",
        "category_create" => "savings.daily.category.create"
      }.freeze
      rescue_from ArgumentError, ActiveRecord::RecordInvalid do |error|
        render json: { errors: [ error.message ] }, status: :unprocessable_entity
      end
      rescue_from ActiveRecord::RecordNotFound do
        render json: { errors: [ "Private daily record not found" ] }, status: :not_found
      end
      rescue_from HouseholdFinance::Operations::Base::StaleOperation, HouseholdFinance::Operations::Runner::IdempotencyConflict do |error|
        render json: { errors: [ error.message ] }, status: :conflict
      end
      rescue_from SavingsChallenge::AccessPolicy::Unavailable do |error|
        render json: { errors: [ error.message ] }, status: :forbidden
      end

      def show
        render json: private_read {
          { **actor_context, calendar: SavingsChallenge::ParticipantSerializer.calendar(@enrollment),
            day: context_day,
            categories: current_household.budget_categories.active.order(:sort_order, :id).map { |category| category.attributes.slice("id", "name", "stack_key") },
            category_options: BudgetCategory::STACK_KEYS.map { |key| { stack_key: key, label: HouseholdFinance::SnapshotBuilder::STACK_LABELS.fetch(key) } } }
        }
      end

      def records
        collection = params[:collection].to_s.to_sym
        result = private_read { reader.page(collection, limit: 50, after_id: params[:cursor].presence, parent_id: params[:parent_id].presence) }
        render json: result.merge(records: result[:records].map { |record| present(record) }, **actor_context)
      rescue KeyError
        render json: { errors: [ "Choose a supported daily collection" ] }, status: :unprocessable_entity
      end

      def mutate
        key = ACTIONS.fetch(params[:review_action].to_s) { raise ArgumentError, "Choose a supported daily action" }
        input = request.request_parameters.to_h.deep_symbolize_keys
        raise ArgumentError, "The server selects the program and participant" if input.key?(:cohort_id)
        result = private_read do
          # Categories belong to the household; the execution must separately
          # retain the program in which this participant reviewed their creation.
          reviewable = key == ACTIONS.fetch("category_create") ? @enrollment : nil
          runner.run(operation_key: key, input: input.merge(cohort_id: @enrollment.cohort_id), idempotency_key: request_key, reviewable: reviewable)
        end
        render json: { record: present(result.subject), replayed: result.replayed?, **actor_context }
      end

      def request_status
        key = ACTIONS.fetch(params[:review_action].to_s) { raise ArgumentError, "Choose a supported daily request" }
        result = private_read do
          resolved = runner.private_request_result(operation_key: key, idempotency_key: request_key)
          if resolved
            require_result_enrollment!(resolved, operation_key: key)
            { state: "committed", record: present(resolved.subject), replayed: true }
          else
            { state: "unknown", can_retry: true }
          end
        end
        render json: result.merge(actor_context)
      rescue ActiveRecord::LockWaitTimeout
        render json: { state: "in_flight", **actor_context }, status: :accepted
      end

      def candidates
        date = SavingsChallenge::Daily::Inputs.elapsed_date!(@enrollment, local_on)
        cursor = params[:cursor].presence && SavingsChallenge::Inputs.id!(params[:cursor])
        result = private_read do
          window = @enrollment.starts_on..[ @enrollment.ends_on, @enrollment.local_today ].min
          authorized_source_transactions = SourceProjectionRevision.joins(source_review_version: :source_review_head)
            .where(household_id: current_household.id, action: %w[create replace])
            .where(source_review_versions: { authorized_on: window })
            .where("source_review_heads.approved_version_id = source_review_versions.id").select(:replacement_transaction_id)
          scope = current_household.household_transactions.where(status: %w[confirmed reconciled])
          scope = scope.where(occurred_on: window).or(scope.where(id: authorized_source_transactions))
          scope = scope.where("id > ?", cursor) if cursor
          scope = scope.where(total_amount_cents: SavingsChallenge::Inputs.integer!(params[:amount_cents], minimum: 1)) if params[:amount_cents].present?
          scope = scope.where("merchant ILIKE ?", "%#{ApplicationRecord.sanitize_sql_like(params[:merchant].to_s)}%") if params[:merchant].present?
          rows = scope.order(:id).includes(transaction_splits: :budget_category).limit(51).to_a
          # Preserve paging over every candidate, including rejected/stale source
          # records; no first-50 filter can hide a later valid canonical match.
          records = rows.first(50).filter_map do |transaction|
            dates = SavingsChallenge::Daily::CanonicalPurchase.new(@enrollment).purchase_dates(transaction)
            next unless dates.include?(date)
            { id: transaction.id, merchant: transaction.merchant, amount_cents: transaction.total_amount_cents,
              posted_on: transaction.occurred_on, purchased_on_candidates: dates,
              splits: transaction.transaction_splits.map { |split| { budget_category_id: split.budget_category_id, amount_cents: split.amount_cents } },
              digest: SavingsChallenge::Daily::CanonicalPurchase.digest(transaction), source_owned: transaction.financial_source_event_id.present? }
          rescue ArgumentError
            nil
          end
          { records: records, next_cursor: rows.length > 50 ? rows[49].id : nil }
        end
        render json: result.merge(actor_context)
      end

      def erase_status
        reflection = own_reflection
        enrollment = reflection.savings_enrollment
        result = ApplicationRecord.transaction do
          ApplicationRecord.connection.execute("SET LOCAL lock_timeout = '2s'")
          enrollment.household.lock!
          SavingsChallenge::Daily::ReadPolicy.erase!(enrollment, user: current_user, lock: true)
          resolved = HouseholdFinance::Operations::Runner.new(enrollment.household, user: current_user).private_request_result(
            operation_key: "savings.daily.reflection.erase", idempotency_key: request_key)
          if resolved
            raise ActiveRecord::RecordNotFound unless resolved.subject.savings_daily_reflection_id == reflection.id
            { state: "committed", erased: true, reflection_id: reflection.id, version_id: resolved.subject.id, replayed: true }
          else
            { state: "unknown", can_retry: true }
          end
        end
        render json: result
      rescue ActiveRecord::LockWaitTimeout
        render json: { state: "in_flight" }, status: :accepted
      end

      def erase_reflection
        reflection = own_reflection
        enrollment = reflection.savings_enrollment
        input = request.request_parameters.to_h.deep_symbolize_keys
        raise ArgumentError, "Review only this reflection's erasure" unless (input.keys - %i[erase_accepted expected_version_id expected_head_lock_version]).empty?
        result = HouseholdFinance::Operations::Runner.new(enrollment.household, user: current_user).run(operation_key: "savings.daily.reflection.erase",
          input: input.merge(cohort_id: enrollment.cohort_id, reflection_id: reflection.id), idempotency_key: request_key)
        render json: { erased: true, reflection_id: reflection.id, version_id: result.subject.id, replayed: result.replayed? }
      end

      private
      def own_reflection
        SavingsDailyReflection.joins(:savings_enrollment).where(savings_enrollments: { user_id: current_user.id }).find(params[:id])
      end
      def disable_caching! = response.set_header("Cache-Control", "private, no-store")
      def local_on = params[:local_on].presence || [ @enrollment.local_today, @enrollment.ends_on ].min.iso8601
      def context_day
        return nil if params[:local_on].blank? && @enrollment.local_today < @enrollment.starts_on
        SavingsChallenge::Daily::DayProjection.new(@enrollment, user: current_user, local_on: local_on).call
      end
      def require_result_enrollment!(result, operation_key:)
        subject = result.subject
        case subject
        when SavingsDailyPurchaseDraft, SavingsDailyPurchaseVersion, SavingsDailyReflectionVersion,
          SavingsDailyCheckInVersion, SavingsCheckpointDraft, SavingsCheckpointVersion
          raise ActiveRecord::RecordNotFound unless subject.savings_enrollment_id == @enrollment.id
        when BudgetCategory
          execution = result.execution
          # Older redacted category executions have no program reference. They
          # cannot be attributed to whichever program happens to be selected.
          raise ActiveRecord::RecordNotFound unless execution.reviewable_type == "SavingsEnrollment" && execution.reviewable_id == @enrollment.id
          CohortReleases::OperationAccess.require!(household: current_household, user: current_user, key: operation_key, cohort: @enrollment.cohort)
        else
          raise ActiveRecord::RecordNotFound
        end
      end

      def actor_context
        { actor_scope: { user_id: current_user.id, household_id: @enrollment&.household_id || current_household.id },
          enrollment_id: @enrollment&.id, cohort_id: @enrollment&.cohort_id }
      end
      def request_key
        value = request.headers["Idempotency-Key"].to_s.strip
        raise ArgumentError, "Idempotency-Key is required" if value.empty?
        value
      end
      def require_challenge!
        membership = current_cohort_membership || raise(SavingsChallenge::AccessPolicy::Unavailable, "Select your available challenge")
        @enrollment = SavingsEnrollment.find_by!(household: current_household, user: current_user, cohort_id: membership.cohort_id)
        SavingsChallenge::Daily::ReadPolicy.call!(@enrollment, user: current_user)
      end
      def private_read
        ApplicationRecord.transaction do
          ApplicationRecord.connection.execute("SET LOCAL lock_timeout = '2s'") if action_name == "request_status"
          current_household.lock!
          require_challenge!
          yield
        end
      end
      def reader = SavingsChallenge::Daily::ParticipantReader.new(@enrollment, user: current_user)
      def runner = HouseholdFinance::Operations::Runner.new(current_household, user: current_user)
      def present(record)
        return record.attributes.slice("id", "name", "stack_key") if record.is_a?(BudgetCategory)
        SavingsChallenge::Daily::ParticipantSerializer.record(record)
      end
    end
  end
end
