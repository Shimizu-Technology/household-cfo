module Api
  module V1
    class SourceReviewsController < BaseController
      wrap_parameters false
      before_action :authenticate_user!
      before_action :require_participant!

      ACTIONS = {
        "account_link" => "source_review.account.link", "stage" => "source_review.draft.stage",
        "approve" => "source_review.draft.approve", "cancel" => "source_review.draft.cancel",
        "coverage" => "source_review.revision.approve", "economic_link" => "source_review.economic.link",
        "project" => "source_review.expense.project"
      }.freeze

      rescue_from ActiveRecord::RecordNotFound do
        render json: { errors: [ "Statement review record not found" ] }, status: :not_found
      end
      rescue_from ArgumentError, ActiveRecord::RecordInvalid do |error|
        render json: { errors: [ error.message ] }, status: :unprocessable_entity
      end
      rescue_from FinancialDocuments::SourceReview::Domain::StaleReview,
        HouseholdFinance::Operations::Base::StaleOperation, HouseholdFinance::Operations::Runner::IdempotencyConflict do |error|
        render json: { errors: [ error.message ] }, status: :conflict
      end
      rescue_from SavingsChallenge::AccessPolicy::Unavailable do |error|
        render json: { errors: [ error.message ] }, status: :forbidden
      end

      def mutate
        body = request.request_parameters.to_h.deep_symbolize_keys
        raise ArgumentError, "Review request contains unsupported fields" unless (body.keys - %i[revision_id input]).empty?
        input = body.fetch(:input).to_h.deep_symbolize_keys
        action = params[:review_action].to_s
        operation = ACTIONS.fetch(action) { raise ArgumentError, "Unknown statement review action" }
        key = request.headers["Idempotency-Key"].to_s.strip
        raise ArgumentError, "Idempotency-Key is required" if key.empty?
        result = ApplicationRecord.transaction do
          current_household.lock!
          domain.authorize!
          document = current_household.financial_document_imports.lock.find(params[:document_import_id])
          revision = document.financial_extraction_revisions.order(revision_number: :desc, id: :desc).first
          unless revision && revision.id.to_s == body[:revision_id].to_s
            raise FinancialDocuments::SourceReview::Domain::StaleReview, "The extraction changed. Refresh this statement; nothing changed."
          end
          require_revision_subject!(action, input, revision)
          execution = HouseholdFinance::Operations::Runner.new(current_household, user: current_user, cohort_membership: current_cohort_membership).run(
            operation_key: operation, input: input, idempotency_key: key)
          { record: FinancialDocuments::SourceReview::ParticipantPresenter.new(current_household, revision).record(execution.subject),
            replayed: execution.replayed? }
        end
        response.set_header("Cache-Control", "no-store")
        render json: result
      rescue KeyError, TypeError
        render json: { errors: [ "Statement review request is missing required fields" ] }, status: :unprocessable_entity
      end

      def accounts
        cursor = params.fetch(:cursor, "0").to_s
        raise ArgumentError, "Invalid account cursor" unless cursor.match?(/\A\d+\z/)
        rows = SourceTrackedAccount.where(household: current_household).where("id > ?", cursor.to_i).order(:id).limit(51).to_a
        response.set_header("Cache-Control", "no-store")
        render json: { records: rows.first(50).map { |account| { id: account.id, label: account.label, account_basis: account.account_basis, account_id: account.account_id } },
          next_cursor: rows.length > 50 ? rows[49].id : nil }
      end

      def candidates
        document = current_household.financial_document_imports.find(params[:document_import_id])
        revision = document.financial_extraction_revisions.order(revision_number: :desc, id: :desc).first
        raise ActiveRecord::RecordNotFound unless revision
        event = revision.financial_source_events.find(params[:event_id])
        identity = domain.account_heads.find_by(financial_source_account_id: event.financial_source_account_id)&.approved_version
        raise ArgumentError, "Review this account identity first" unless identity
        cursor = params.fetch(:cursor, "0").to_s
        raise ArgumentError, "Invalid row cursor" unless cursor.match?(/\A\d+\z/)
        filter = params.fetch(:filter, "duplicate").to_s
        raise ArgumentError, "Choose duplicate or link candidates" unless filter.in?(%w[duplicate link])
        rows = domain.versions.joins(:source_review_head, :source_account_identity_version)
          .where("source_review_heads.approved_version_id = source_review_versions.id")
          .where(source_review_versions: { disposition: "include" })
          .where.not(source_review_heads: { financial_source_event_id: event.id })
        if filter == "duplicate"
          amount = params.key?(:signed_amount_cents) ? params[:signed_amount_cents].to_s : event.signed_amount_cents&.to_s
          date = params.key?(:posted_on) ? params[:posted_on].to_s : event.posted_on&.iso8601
          raise ArgumentError, "Use exact signed integer cents" unless amount&.match?(/\A-?\d+\z/) && amount.to_i.abs <= FinancialDocuments::AccountingContract::CENT_LIMIT
          raise ArgumentError, "Use an exact posted date" unless date&.match?(/\A\d{4}-\d{2}-\d{2}\z/)
          begin
            Date.iso8601(date)
          rescue Date::Error
            raise ArgumentError, "Invalid posted date"
          end
          rows = rows.where(source_review_versions: { signed_amount_cents: amount.to_i, posted_on: date })
            .where(source_account_identity_versions: { source_tracked_account_id: identity.source_tracked_account_id })
        end
        rows = rows.where("source_review_versions.id > ?", cursor.to_i).order(:id).limit(51).to_a
        response.set_header("Cache-Control", "no-store")
        presenter = FinancialDocuments::SourceReview::ParticipantPresenter.new(current_household, revision)
        render json: { records: rows.first(50).map { |row| presenter.record(row) }, next_cursor: rows.length > 50 ? rows[49].id : nil }
      end

      def request_status
        operation = ACTIONS.fetch(params[:review_action].to_s) { raise ArgumentError, "Unknown review action" }
        result = ApplicationRecord.transaction do
          ApplicationRecord.connection.execute("SET LOCAL lock_timeout = '2s'")
          current_household.lock!
          domain.authorize!
          document = current_household.financial_document_imports.find(params[:document_import_id])
          execution = HouseholdFinance::Operations::Runner.new(current_household, user: current_user, cohort_membership: current_cohort_membership).private_request_result(
            operation_key: operation, idempotency_key: request.headers["Idempotency-Key"])
          if execution
            subject = execution.subject
            subject_revision = case subject
            when SourceReviewDraft then subject.source_review_head.financial_source_event.financial_extraction_revision
            when SourceReviewVersion then subject.financial_source_event.financial_extraction_revision
            when SourceAccountIdentityVersion then subject.source_account_review_head.financial_source_account.financial_extraction_revision
            when SourceRevisionApproval then subject.financial_extraction_revision
            when SourceProjectionRevision then subject.source_review_version.financial_source_event.financial_extraction_revision
            when SourceEconomicGroupVersion
              subject.source_economic_memberships.map { |member| member.source_review_version.financial_source_event.financial_extraction_revision }.find { |revision| revision.financial_document_import_id == document.id }
            end
            raise ActiveRecord::RecordNotFound unless subject_revision&.financial_document_import_id == document.id
            { state: "committed", record: FinancialDocuments::SourceReview::ParticipantPresenter.new(current_household, subject_revision).record(subject), replayed: true }
          else
            { state: "unknown", can_retry: true }
          end
        end
        response.set_header("Cache-Control", "no-store")
        render json: result
      rescue ActiveRecord::LockWaitTimeout
        response.set_header("Cache-Control", "no-store")
        render json: { state: "in_flight" }, status: :accepted
      end

      private

      def domain
        @domain ||= FinancialDocuments::SourceReview::Domain.new(current_household, user: current_user)
      end

      def require_participant!
        membership = current_household.household_memberships.find_by(user_id: current_user.id)
        return if current_user.participant? && membership&.role.in?(%w[owner partner])
        render json: { errors: [ "Only a current participant can review their private statements." ] }, status: :forbidden
      end

      def require_revision_subject!(action, input, revision)
        event_ids = revision.financial_source_events.select(:id)
        case action
        when "account_link"
          revision.financial_source_accounts.find(input.fetch(:source_account_id))
        when "stage"
          revision.financial_source_events.find(input.fetch(:event_id))
        when "approve", "cancel"
          draft = domain.drafts.find(input.fetch(:draft_id))
          revision.financial_source_events.find(draft.source_review_head.financial_source_event_id)
        when "coverage"
          raise ActiveRecord::RecordNotFound unless input.fetch(:revision_id).to_i == revision.id
        when "project"
          version = domain.versions.find(input.fetch(:version_id))
          revision.financial_source_events.find(version.source_review_head.financial_source_event_id)
        when "economic_link"
          ids = Array(input.fetch(:members)).map { |member| member.fetch(:source_review_version_id) }
          versions = domain.versions.where(id: ids)
          raise ActiveRecord::RecordNotFound unless versions.count == ids.uniq.length &&
            versions.joins(:source_review_head).where(source_review_heads: { financial_source_event_id: event_ids }).exists?
        end
      end
    end
  end
end
