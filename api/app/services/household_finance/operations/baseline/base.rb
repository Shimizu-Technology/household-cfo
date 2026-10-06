module HouseholdFinance
  module Operations
    module Baseline
      class Base < Operations::Base
        ACTOR_REQUIRED = true
        SENSITIVE_AUDIT = true
        VERSION = 1

        def initialize(household, user: nil)
          super(household)
          @user = user
        end

        def prepare(input)
          ApplicationRecord.transaction do
            household.lock!
            authorize!
            super
          end
        end

        def execute!(prepared, source:)
          ApplicationRecord.transaction do
            household.lock!
            super
          end
        end

        def authorize_replay!(subject)
          ApplicationRecord.transaction do
            household.lock!
            authorize!
            raise ArgumentError, "Baseline approval belongs to a different participant" unless subject.is_a?(FinancialBaselineVersion) && subject.household_id == household.id && subject.financial_baseline_head.participant_user_id == user.id
          end
        end

        private

        attr_reader :user
        def authorize!
          FinancialDocuments::SourceReview::Domain.new(household, user: user).authorize!
          CohortReleases::OperationAccess.require!(household: household, user: user, key: self.class::KEY, membership: release_membership)
        end
        def ensure_plan!(_input) = nil
        def heads = FinancialBaselineHead.current_picture.where(household: household, participant_user: user)
        def subject_for(_input, lock:) = (lock ? heads.lock.first : heads.first) || household

        def normalize(raw)
          input = raw.to_h.deep_symbolize_keys
          base_id = input.fetch(:base_version_id)
          lock_version = input.fetch(:base_lock_version)
          raise ArgumentError, "Use exact baseline version and lock identities" unless (base_id.nil? || base_id.is_a?(Integer) && base_id.positive?) && lock_version.is_a?(Integer) && lock_version >= 0
          raise ArgumentError, "Revise requires a prior approved baseline" if self.class::REVISION && base_id.nil?
          raise ArgumentError, "First approval cannot overwrite a baseline; use revise" if !self.class::REVISION && base_id
          status = input.fetch(:coverage_status).to_s
          raise ArgumentError, "Choose complete, partial or manual baseline coverage" unless status.in?(%w[complete partial manual])
          reason = input.fetch(:reason).to_s.squish
          raise ArgumentError, "Explain this baseline approval in no more than 500 characters" if reason.blank? || reason.length > 500
          { request: FinancialBaselines::Request.new(household).call(input.fetch(:request)), base_version_id: base_id, base_lock_version: lock_version,
            expected_preview_digest: input.fetch(:expected_preview_digest).to_s, coverage_status: status, reason: reason }
        rescue KeyError, TypeError
          raise ArgumentError, "Baseline approval is missing required fields"
        end

        def canonical_snapshot(_subject, input, lock:)
          head = heads.first
          preview = FinancialBaselines::Preview.new(household, user: user).call(input[:request])
          raise StaleOperation, "Review the current baseline preview before approval" unless input[:expected_preview_digest] == preview[:digest]
          raise ArgumentError, "Complete baseline coverage is unavailable: #{preview[:deficiencies].join(', ')}" if input[:coverage_status] == "complete" && !preview[:complete_eligible]
          { head_id: head&.id, approved_version_id: head&.approved_version_id, lock_version: head&.lock_version || 0, preview_digest: preview[:digest] }
        end

        def validate_execution!(_subject, _input, prepared:, source:)
          authorize!
        end

        def predicted_after(_before, input)
          { digest: input[:expected_preview_digest], snapshot_digest: input[:expected_preview_digest], coverage_status: input[:coverage_status], reason: input[:reason] }
        end

        def mutate!(_subject, input, prepared:)
          head = heads.first || FinancialBaselineHead.create!(household: household, participant_user: user)
          head.lock!
          raise StaleOperation, stale_message unless head.approved_version_id == input[:base_version_id] && head.lock_version == input[:base_lock_version]
          preview = FinancialBaselines::Preview.new(household, user: user).call(input[:request])
          raise StaleOperation, stale_message unless preview[:digest] == input[:expected_preview_digest]
          version = head.financial_baseline_versions.create!(household: household, approved_by_user: user,
            version_number: head.financial_baseline_versions.maximum(:version_number).to_i + 1, supersedes_id: head.approved_version_id,
            window_start_on: input[:request][:window_start_on], window_end_on: input[:request][:window_end_on], coverage_status: input[:coverage_status],
            calculation_version: FinancialBaselines::Preview::CALCULATION_VERSION, digest: preview[:digest], snapshot: preview.except(:digest), reason: input[:reason])
          head.update!(approved_version: version)
          version
        end

        def canonical_after_snapshot(subject, input, prepared:)
          { digest: subject.digest, snapshot_digest: PreparedOperation.fingerprint(subject.snapshot), coverage_status: subject.coverage_status, reason: subject.reason }
        end

        def verify_after!(predicted, actual)
          raise ArgumentError, "Baseline approval result did not match the reviewed request" unless predicted.deep_stringify_keys == actual.deep_stringify_keys
          true
        end

        def stale_message = "The baseline or approved financial records changed. Review a new preview; nothing changed."
      end
    end
  end
end
