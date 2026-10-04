module HouseholdFinance
  module Operations
    module Savings
      class ZeroAttest < Base
        KEY = "savings.zero.attest"
        VERSION = 1

        private

        def normalize(input)
          input = normal_ids(input, required: %i[known_zero cutoff_on expected_enrollment_lock_version])
          input.merge(known_zero: SavingsChallenge::Inputs.accepted!(input[:known_zero]),
            cutoff_on: SavingsChallenge::Inputs.date!(input[:cutoff_on]).iso8601,
            expected_enrollment_lock_version: SavingsChallenge::Inputs.integer!(input[:expected_enrollment_lock_version], minimum: 0))
        end

        def subject_for(input, lock:)
          enrollment_for(input, lock: lock)
        end

        def mutate!(enrollment, input, prepared:)
          check_version!(enrollment.lock_version, input[:expected_enrollment_lock_version])
          cutoff = SavingsChallenge::Inputs.date!(input[:cutoff_on])
          raise ArgumentError, "Zero attestation must cover an elapsed challenge date" unless (enrollment.starts_on..[ enrollment.ends_on, enrollment.local_today ].min).cover?(cutoff)
          scope = enrollment.savings_entry_versions.joins(:savings_entry)
            .where("savings_entry_versions.id = savings_entries.current_approved_version_id")
            .where(effective_on: ..cutoff).where(funding_source: HouseholdFinance::SavingsProjection::ELIGIBLE_FUNDING_SOURCES + [ "withdrawal" ])
          raise ArgumentError, "Approved savings entries already establish the reported result" if scope.exists?
          previous = enrollment.savings_zero_attestations.where(cutoff_on: cutoff).order(approval_sequence: :desc).first
          enrollment.savings_zero_attestations.create!(approved_by_user: user, cutoff_on: cutoff, previous_attestation: previous,
            approval_sequence: enrollment.advance_approval_sequence!, approved_at: Time.current)
        end

        def planned_record(before, input)
          { savings_enrollment_id: before.fetch("id"), approved_by_user_id: user.id, cutoff_on: input[:cutoff_on] }
        end
      end
    end
  end
end
