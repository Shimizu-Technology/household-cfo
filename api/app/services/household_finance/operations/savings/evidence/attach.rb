module HouseholdFinance
  module Operations
    module Savings
      module Evidence
        class Attach < Savings::Base
          KEY = "savings.evidence.attach"
          VERSION = 1

          private

          def normalize(input)
            input = normal_ids(input, required: %i[entry_version_id expected_evidence_version_id expected_head_lock_version accepted participant_ownership_accepted new_money_reservation_accepted proofs reason])
            normalize_common(input).merge(
              participant_ownership_accepted: SavingsChallenge::Inputs.accepted!(input[:participant_ownership_accepted]),
              new_money_reservation_accepted: SavingsChallenge::Inputs.accepted!(input[:new_money_reservation_accepted]), proofs: normalize_proofs(input[:proofs]))
          end

          def normalize_common(input)
            input.merge(entry_version_id: SavingsChallenge::Inputs.id!(input[:entry_version_id]),
              expected_evidence_version_id: SavingsChallenge::Inputs.id!(input[:expected_evidence_version_id], nullable: true),
              expected_head_lock_version: SavingsChallenge::Inputs.integer!(input[:expected_head_lock_version], minimum: 0),
              accepted: SavingsChallenge::Inputs.accepted!(input[:accepted]), reason: SavingsChallenge::Inputs.text!(input[:reason], required: true))
          end

          def normalize_proofs(proofs)
            raise ArgumentError, "Review between one and twenty source proofs" unless proofs.instance_of?(Array) && proofs.size.between?(1, 20)
            proofs.map do |proof|
              raise ArgumentError, "Evidence proof must be an object" unless proof.instance_of?(Hash)
              SavingsChallenge::Inputs.keys!(proof, required: %i[source_review_version_id expected_source_digest expected_account_identity_digest amount_cents economic_group_version_id expected_group_digest])
              group_id = SavingsChallenge::Inputs.id!(proof[:economic_group_version_id], nullable: true)
              raise ArgumentError, "Group digest must accompany a group identity" unless group_id ? valid_digest?(proof[:expected_group_digest]) : proof[:expected_group_digest].nil?
              %i[expected_source_digest expected_account_identity_digest].each { |key| raise ArgumentError, "Review exact source digests" unless valid_digest?(proof[key]) }
              proof.merge(source_review_version_id: SavingsChallenge::Inputs.id!(proof[:source_review_version_id]),
                economic_group_version_id: group_id, amount_cents: SavingsChallenge::Inputs.money!(proof[:amount_cents], positive: true))
            end
          end

          def valid_digest?(value)
            value.instance_of?(String) && value.match?(/\A[0-9a-f]{64}\z/)
          end

          def subject_for(input, lock:)
            @enrollment = enrollment_for(input, lock: lock)
            @entry_version = @enrollment.savings_entry_versions.find(input[:entry_version_id])
            @entry_version.savings_entry.lock! if lock
            raise ArgumentError, "Evidence must describe the current positive eligible contribution" unless @entry_version.savings_entry.current_approved_version_id == @entry_version.id && @entry_version.signed_cents.positive? && HouseholdFinance::SavingsProjection::ELIGIBLE_FUNDING_SOURCES.include?(@entry_version.funding_source)
            @head = SavingsEvidenceAllocation.find_by(savings_entry_version: @entry_version)
            @head&.lock! if lock
            @entry_version
          end

          def canonical_snapshot(subject, input, lock:)
            snapshots = proof_snapshots(input)
            { entry_version_id: subject.id, evidence_version_id: @head&.current_version_id, head_lock_version: @head&.lock_version || 0,
              proof_snapshots: snapshots }
          end

          def proof_snapshots(input)
            snapshots = input.fetch(:proofs).map { |proof| SavingsChallenge::EvidenceProof.new(@enrollment).resolve(proof) }
            raise ArgumentError, "Evidence exceeds the contribution" if snapshots.sum { |proof| proof.fetch("amount_cents") } > @entry_version.signed_cents
            bindings = snapshots.flat_map { |proof| proof.fetch("bindings") }
            raise ArgumentError, "The same canonical movement was selected twice" unless bindings.map { |row| row.fetch("event_id") }.uniq.size == bindings.size
            resolver = SavingsChallenge::EvidenceProof.new(@enrollment)
            raise ArgumentError, "Evidence grouping requires renewed review" unless resolver.current?(snapshots, cutoff_on: @enrollment.local_today)
            snapshots
          end

          def mutate!(_subject, input, prepared:)
            check_version!(@head&.current_version_id, input[:expected_evidence_version_id])
            check_version!(@head&.lock_version || 0, input[:expected_head_lock_version])
            snapshots = proof_snapshots(input)
            snapshots.flat_map { |proof| proof.fetch("bindings") }.each do |binding|
              reserved = SavingsEvidenceCapacity.joins(savings_evidence_version: :savings_evidence_allocation)
                .where(financial_source_event_id: binding.fetch("event_id"))
                .where("savings_evidence_allocations.current_version_id = savings_evidence_capacities.savings_evidence_version_id")
              reserved = reserved.where.not(savings_evidence_versions: { savings_evidence_allocation_id: @head.id }) if @head
              raise ArgumentError, "This canonical movement is already allocated; review or revoke its existing allocations" if reserved.sum(:reserved_cents) + binding.fetch("reserved_cents") > binding.fetch("capacity_cents")
            end
            @head ||= SavingsEvidenceAllocation.create!(household: household, savings_enrollment: @enrollment, savings_entry_version: @entry_version)
            previous = @head.current_version
            version = @head.savings_evidence_versions.create!(savings_enrollment: @enrollment, approved_by_user: user,
              previous_version: previous, version_number: previous ? previous.version_number + 1 : 1,
              approval_sequence: @enrollment.advance_approval_sequence!, state: evidence_state, supported_cents: snapshots.sum { |proof| proof.fetch("amount_cents") },
              proof_snapshot: snapshots, participant_ownership_accepted: evidence_state == "attached", new_money_reservation_accepted: evidence_state == "attached",
              digest: PreparedOperation.fingerprint(entry_version_id: @entry_version.id, state: evidence_state, proofs: snapshots), reason: input[:reason], approved_at: Time.current)
            snapshots.flat_map { |proof| proof.fetch("bindings") }.each do |binding|
              version.savings_evidence_capacities.create!(financial_source_event_id: binding.fetch("event_id"), source_review_version_id: binding.fetch("source_review_version_id"),
                capacity_cents: binding.fetch("capacity_cents"), reserved_cents: binding.fetch("reserved_cents"))
            end
            @head.update!(current_version: version)
            version
          end

          def evidence_state = "attached"

          def predicted_after(_before, _input) = { "private_change_completed" => true }
          def canonical_after_snapshot(_subject, _input, prepared:) = { "private_change_completed" => true }
        end
      end
    end
  end
end
