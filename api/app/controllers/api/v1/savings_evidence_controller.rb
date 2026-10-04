module Api
  module V1
    class SavingsEvidenceController < BaseController
      wrap_parameters false
      before_action :authenticate_user!
      ACTIONS = { "attach" => "savings.evidence.attach", "revoke" => "savings.evidence.revoke" }.freeze
      rescue_from ArgumentError, ActiveRecord::RecordInvalid do |error|
        render json: { errors: [ error.message ] }, status: :unprocessable_entity
      end
      rescue_from ActiveRecord::RecordNotFound do
        render json: { errors: [ "Private evidence record not found" ] }, status: :not_found
      end
      rescue_from HouseholdFinance::Operations::Base::StaleOperation, HouseholdFinance::Operations::Runner::IdempotencyConflict do |error|
        render json: { errors: [ error.message ] }, status: :conflict
      end
      rescue_from SavingsChallenge::AccessPolicy::Unavailable do |error|
        render json: { errors: [ error.message ] }, status: :forbidden
      end

      def show
        result = private_read do
          entry = own_entry(params[:entry_version_id])
          head = SavingsEvidenceAllocation.find_by(savings_entry_version: entry)
          versions = head ? head.savings_evidence_versions.where("id > ?", cursor).order(:id).limit(51).to_a : []
          { entry: present(entry), entry_is_current: entry.savings_entry.current_approved_version_id == entry.id,
            head: head && head.attributes.slice("id", "current_version_id", "lock_version"),
            current_version: head&.current_version && present(head.current_version),
            records: versions.first(50).map { |version| present(version) }, next_cursor: versions.size > 50 ? versions[49].id : nil }
        end
        render json: result.merge(actor_context)
      end

      def candidates
        result = private_read do
          entry = own_entry(params[:entry_version_id])
          raise ArgumentError, "Choose a current positive eligible contribution" unless entry.savings_entry.current_approved_version_id == entry.id && entry.signed_cents.positive? && HouseholdFinance::SavingsProjection::ELIGIBLE_FUNDING_SOURCES.include?(entry.funding_source)
          head = SavingsEvidenceAllocation.find_by(savings_entry_version: entry)
          rows = SourceReviewVersion.where(household: current_household, disposition: "include", event_type: %w[income transfer],
            posted_on: @enrollment.starts_on..[ @enrollment.ends_on, @enrollment.local_today ].min)
            .joins(:source_review_head).where("source_review_heads.approved_version_id = source_review_versions.id")
            .where("source_review_versions.id > ?", cursor).order(:id).limit(51).to_a
          groups = FinancialDocuments::SourceReview::EconomicLinker.valid_current_versions(current_household)
          records = rows.first(50).filter_map { |version| candidate(version, entry: entry, head: head, groups: groups) }
          { records: records, next_cursor: rows.size > 50 ? rows[49].id : nil }
        end
        render json: result.merge(actor_context)
      end

      def mutate
        key = ACTIONS.fetch(params[:review_action].to_s) { raise ArgumentError, "Choose attach or revoke evidence" }
        input = request.request_parameters.to_h.deep_symbolize_keys
        raise ArgumentError, "The server selects the program and participant" if input.key?(:cohort_id)
        result = private_read { runner.run(operation_key: key, input: input.merge(cohort_id: @enrollment.cohort_id), idempotency_key: request_key) }
        render json: { record: present(result.subject), replayed: result.replayed?, **actor_context }
      end

      def request_status
        key = ACTIONS.fetch(params[:review_action].to_s) { raise ArgumentError, "Choose attach or revoke evidence" }
        result = private_read do
          entry = own_entry(params[:entry_version_id])
          resolved = runner.private_request_result(operation_key: key, idempotency_key: request_key)
          if resolved
            version = resolved.subject
            raise ActiveRecord::RecordNotFound unless version.savings_evidence_allocation.savings_entry_version_id == entry.id
            { state: "committed", record: present(version), replayed: true }
          else
            { state: "unknown", can_retry: true }
          end
        end
        render json: result.merge(actor_context)
      rescue ActiveRecord::LockWaitTimeout
        render json: { state: "in_flight", **actor_context }, status: :accepted
      end

      private

      def private_read
        response.set_header("Cache-Control", "private, no-store")
        ApplicationRecord.transaction do
          ApplicationRecord.connection.execute("SET LOCAL lock_timeout = '2s'") if action_name == "request_status"
          current_household.lock!
          membership = current_cohort_membership || raise(SavingsChallenge::AccessPolicy::Unavailable, "Select an available savings challenge")
          @enrollment = SavingsEnrollment.find_by!(household: current_household, user: current_user, cohort_id: membership.cohort_id)
          SavingsChallenge::AccessPolicy.new(household: current_household, user: current_user, cohort: @enrollment.cohort, enrollment: @enrollment).call!
          CohortReleases::OperationAccess.require!(household: current_household, user: current_user, key: "savings.evidence.attach", cohort: @enrollment.cohort)
          yield
        end
      end

      def candidate(version, entry:, head:, groups:)
        matching = groups.select { |group| group.source_economic_memberships.any? { |member| member.source_review_version_id == version.id } }
        return nil if matching.size > 1
        group = matching.first
        input = { source_review_version_id: version.id, expected_source_digest: version.digest,
          expected_account_identity_digest: version.source_account_identity_version.digest, amount_cents: 1,
          economic_group_version_id: group&.id, expected_group_digest: group&.digest }
        proof = SavingsChallenge::EvidenceProof.new(@enrollment).resolve(input)
        available = proof.fetch("bindings").map do |binding|
          reservations = SavingsEvidenceCapacity.joins(savings_evidence_version: :savings_evidence_allocation)
            .where(financial_source_event_id: binding.fetch("event_id"))
            .where("savings_evidence_allocations.current_version_id = savings_evidence_capacities.savings_evidence_version_id")
          reservations = reservations.where.not(savings_evidence_versions: { savings_evidence_allocation_id: head.id }) if head
          [ binding.fetch("capacity_cents") - reservations.sum(:reserved_cents), 0 ].max
        end.min
        document = version.financial_source_event.financial_extraction_revision.financial_document_import
        { **input.except(:amount_cents), merchant: version.merchant, posted_on: version.posted_on, signed_amount_cents: version.signed_amount_cents,
          account_label: version.source_tracked_account.label, movement_kind: group ? "reviewed_asset_transfer" : "reviewed_income",
          canonical_event_ids: proof.fetch("bindings").map { |binding| binding.fetch("event_id") }.sort,
          movement_legs: SourceReviewVersion.where(household: current_household, id: proof.fetch("bindings").map { |binding| binding.fetch("source_review_version_id") })
            .includes(source_account_identity_version: :source_tracked_account, source_review_head: { financial_source_event: { financial_extraction_revision: :financial_document_import } }).order(:id).map { |leg| movement_leg(leg) },
          movement_capacity_cents: proof.fetch("capacity_cents"), available_cents: [ available, entry.signed_cents ].min,
          document_import_id: document&.id, filename: document&.filename, source_available: document&.source_available? == true }
      rescue ArgumentError, ActiveRecord::RecordNotFound
        nil
      end

      def movement_leg(version)
        document = version.financial_source_event.financial_extraction_revision.financial_document_import
        { merchant: version.merchant, posted_on: version.posted_on, signed_amount_cents: version.signed_amount_cents,
          account_label: version.source_tracked_account.label, filename: document&.filename, source_available: document&.source_available? == true }
      end

      def cursor = params[:cursor].present? ? SavingsChallenge::Inputs.id!(params[:cursor]) : 0
      def own_entry(id) = @enrollment.savings_entry_versions.find(SavingsChallenge::Inputs.id!(id))
      def runner = HouseholdFinance::Operations::Runner.new(current_household, user: current_user)
      def present(record) = SavingsChallenge::ParticipantSerializer.record(record)
      def actor_context = { actor_scope: { user_id: current_user.id, household_id: current_household.id }, enrollment_id: @enrollment&.id }
      def request_key
        value = request.headers["Idempotency-Key"].to_s.strip
        raise ArgumentError, "Idempotency-Key is required" if value.empty?
        value
      end
    end
  end
end
