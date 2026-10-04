module Api
  module V1
    class FinancialBaselinesController < BaseController
      wrap_parameters false
      before_action :authenticate_user!
      before_action :require_private_participant!
      before_action :disable_caching!

      rescue_from ActiveRecord::RecordNotFound do
        render json: { errors: [ "Private baseline record not found" ] }, status: :not_found
      end
      rescue_from ArgumentError, ActiveRecord::RecordInvalid do |error|
        render json: { errors: [ error.message ] }, status: :unprocessable_entity
      end
      rescue_from HouseholdFinance::Operations::Base::StaleOperation, HouseholdFinance::Operations::Runner::IdempotencyConflict do |error|
        render json: { errors: [ error.message ] }, status: :conflict
      end
      rescue_from SavingsChallenge::AccessPolicy::Unavailable do |error|
        render json: { errors: [ error.message ] }, status: :forbidden
      end

      def show
        result = private_read { reader.current }
        render json: result.merge(actor_context).merge(approved_version: result[:approved_version] && present(result[:approved_version]))
      end

      def history
        cursor = params.fetch(:cursor, "0").to_s
        raise ArgumentError, "Invalid baseline cursor" unless cursor.match?(/\A\d+\z/)
        result = private_read do
          head = FinancialBaselineHead.find_by(household: current_household, participant_user: current_user)
          versions = head ? head.financial_baseline_versions.where("id > ?", cursor.to_i).order(:id).limit(51).to_a : []
          { records: versions.first(50).map { |version| present(version) }, next_cursor: versions.length > 50 ? versions[49].id : nil }
        end
        render json: result.merge(actor_context)
      end

      def context
        cursor = params.fetch(:cursor, "0").to_s
        raise ArgumentError, "Invalid statement cursor" unless cursor.match?(/\A\d+\z/)
        result = private_read do
          sources = current_household.financial_document_imports.where("id > ?", cursor.to_i).order(:id).limit(51).to_a
          records = sources.first(50).filter_map do |document|
            revision = document.financial_extraction_revisions.order(revision_number: :desc, id: :desc).first
            next unless revision&.contract_version == FinancialDocuments::AccountingContract::VERSION
            state = FinancialDocuments::SourceReview::ApprovalState.new(current_household, revision).call
            approval = SourceRevisionApproval.where(household: current_household, financial_extraction_revision: revision).order(version_number: :desc).first
            identities = SourceAccountReviewHead.where(household: current_household, financial_source_account_id: revision.financial_source_accounts.select(:id)).includes(approved_version: :source_tracked_account)
            { document_import_id: document.id, revision_id: revision.id, filename: document.filename,
              source_available: document.source_available?, coverage_status: approval&.coverage_status,
              coverage_current: approval&.digest == state[:content_digest], approved_rows: state[:approved_rows], total_rows: state[:represented_rows],
              accounts: identities.filter_map { |head| version = head.approved_version; next unless version
                { tracked_account_id: version.source_tracked_account_id, label: version.source_tracked_account.label,
                  period_start_on: version.statement_facts["period_start_on"], period_end_on: version.statement_facts["period_end_on"] } } }
          end
          { records: records, next_cursor: sources.length > 50 ? sources[49].id : nil,
            categories: current_household.budget_categories.active.order(:sort_order, :id).pluck(:id, :name).map { |id, name| { id: id, name: name } } }
        end
        render json: result.merge(actor_context)
      end

      def observations
        kind = params.fetch(:kind, "actual").to_s
        raise ArgumentError, "Choose actual, purchase or withdrawal observations" unless kind.in?(%w[actual purchase withdrawal])
        cursor = params.fetch(:cursor, "0").to_s
        raise ArgumentError, "Invalid observation cursor" unless cursor.match?(/\A\d+\z/)
        dates = FinancialBaselines::Request.new(current_household).call(window_start_on: params[:window_start_on], window_end_on: params[:window_end_on])
        result = private_read do
          if kind == "actual"
            records = current_household.household_transactions.where(status: %w[confirmed reconciled], financial_source_event_id: nil,
              occurred_on: dates[:window_start_on]..dates[:window_end_on]).where("id > ?", cursor.to_i).order(:id).includes(transaction_splits: :budget_category).limit(51).to_a
            visible = records.first(50).map do |record|
              { id: record.id, posted_on: record.occurred_on, merchant: record.merchant, amount_cents: record.total_amount_cents,
                source_type: record.source_type, digest: FinancialDocuments::SourceReview::ProjectionCorrector.snapshot_digest(record),
                splits: record.transaction_splits.map { |split| { budget_category_id: split.budget_category_id, category_name: split.budget_category&.name, amount_cents: split.amount_cents } } }
            end
          else
            records = SourceReviewVersion.where(household: current_household, disposition: "include",
              event_type: kind == "withdrawal" ? "cash_withdrawal" : %w[purchase fee interest], posted_on: dates[:window_start_on]..dates[:window_end_on])
              .joins(:source_review_head, source_account_identity_version: :source_account_review_head)
              .where("source_review_heads.approved_version_id = source_review_versions.id AND source_account_review_heads.approved_version_id = source_review_versions.source_account_identity_version_id")
              .where("source_review_versions.id > ?", cursor.to_i).order(:id).limit(51).to_a
            presenter = FinancialDocuments::SourceReview::ParticipantPresenter.new(current_household, nil)
            visible = records.first(50).map { |record| presenter.record(record) }
          end
          { kind: kind, records: visible, next_cursor: records.length > 50 ? records[49].id : nil }
        end
        render json: result.merge(actor_context)
      end

      def request_status
        action = params[:approval_action].to_s
        raise ArgumentError, "Choose approve or revise request status" unless action.in?(%w[approve revise])
        result = private_read do
          execution = HouseholdFinance::Operations::Runner.new(current_household, user: current_user, cohort_membership: current_cohort_membership).private_request_result(
            operation_key: "baseline.#{action}", idempotency_key: request.headers["Idempotency-Key"])
          if execution
            version = execution.subject
            raise ActiveRecord::RecordNotFound unless version.is_a?(FinancialBaselineVersion) && version.household_id == current_household.id && version.financial_baseline_head.participant_user_id == current_user.id
            { state: "committed", record: present(version), replayed: true }
          else
            { state: "unknown", can_retry: true }
          end
        end
        render json: result.merge(actor_context)
      rescue ActiveRecord::LockWaitTimeout
        render json: { state: "in_flight", **actor_context }, status: :accepted
      end

      def preview
        body = request.request_parameters.to_h.deep_symbolize_keys
        raise ArgumentError, "Preview accepts only a baseline request" unless body.keys == [ :request ]
        result = private_read { FinancialBaselines::Preview.new(current_household, user: current_user).call(body.fetch(:request)) }
        render json: FinancialBaselines::Preview.presentation(result).merge(actor_context)
      rescue KeyError, TypeError
        render json: { errors: [ "A baseline request is required" ] }, status: :unprocessable_entity
      end

      def approve
        mutate("baseline.approve")
      end

      def revise
        mutate("baseline.revise")
      end

      private

      def private_read
        ApplicationRecord.transaction do
          ApplicationRecord.connection.execute("SET LOCAL lock_timeout = '2s'") if action_name == "request_status"
          current_household.lock!
          FinancialDocuments::SourceReview::Domain.new(current_household, user: current_user).authorize!
          CohortReleases::OperationAccess.require!(household: current_household, user: current_user,
            key: "baseline.approve", membership: current_cohort_membership)
          yield
        end
      end

      def actor_context
        { actor_scope: { user_id: current_user.id, household_id: current_household.id },
          time_zone: "Pacific/Guam", local_today: Time.current.in_time_zone("Pacific/Guam").to_date }
      end

      def reader = FinancialBaselines::Reader.new(current_household, user: current_user)

      def require_private_participant!
        membership = current_household.household_memberships.find_by(user: current_user)
        return if current_user.participant? && membership&.role.in?(%w[owner partner])
        render json: { errors: [ "Only a current participant can inspect their private spending baseline." ] }, status: :forbidden
      end

      def disable_caching! = response.set_header("Cache-Control", "private, no-store")

      def mutate(key)
        body = request.request_parameters.to_h.deep_symbolize_keys
        fields = %i[request expected_preview_digest base_version_id base_lock_version coverage_status reason]
        raise ArgumentError, "Baseline request contains unsupported fields" unless (body.keys - fields).empty?
        request_key = request.headers["Idempotency-Key"].to_s.strip
        raise ArgumentError, "Idempotency-Key is required" if request_key.empty?
        result = HouseholdFinance::Operations::Runner.new(current_household, user: current_user, cohort_membership: current_cohort_membership).run(
          operation_key: key, input: body, idempotency_key: request_key)
        render json: { record: present(result.subject), replayed: result.replayed? }.merge(actor_context)
      end

      def present(version)
        { id: version.id, version_number: version.version_number, digest: version.digest,
          window_start_on: version.window_start_on, window_end_on: version.window_end_on,
          coverage_status: version.coverage_status, reason: version.reason, supersedes_id: version.supersedes_id,
          calculation_version: version.calculation_version, created_at: version.created_at,
          preview: FinancialBaselines::Preview.presentation(version.snapshot.deep_symbolize_keys.merge(digest: version.digest)) }
      end
    end
  end
end
