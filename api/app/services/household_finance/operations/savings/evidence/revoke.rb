module HouseholdFinance
  module Operations
    module Savings
      module Evidence
        class Revoke < Attach
          KEY = "savings.evidence.revoke"
          VERSION = 1

          private

          def normalize(input)
            input = normal_ids(input, required: %i[entry_version_id expected_evidence_version_id expected_head_lock_version accepted reason])
            input = normalize_common(input)
            raise ArgumentError, "Select the current evidence version to revoke" unless input[:expected_evidence_version_id]
            input
          end

          def subject_for(input, lock:)
            @enrollment = enrollment_for(input, lock: lock)
            @entry_version = @enrollment.savings_entry_versions.find(input[:entry_version_id])
            @head = SavingsEvidenceAllocation.find_by!(savings_entry_version: @entry_version)
            @head.lock! if lock
            raise ArgumentError, "Evidence is already revoked" unless @head.current_version.state == "attached"
            @entry_version
          end

          def proof_snapshots(_input) = []
          def evidence_state = "revoked"
        end
      end
    end
  end
end
