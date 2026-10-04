module HouseholdFinance
  module Operations
    module Savings
      class EntryStage < Base
        KEY = "savings.entry.stage"
        VERSION = 1

        private

        def normalize(input)
          input = normal_ids(input, required: %i[signed_cents effective_on funding_source expected_version_id], optional: %i[entry_id expected_entry_lock_version reason])
          normalized = input.merge(signed_cents: SavingsChallenge::Inputs.money!(input[:signed_cents]),
            effective_on: SavingsChallenge::Inputs.date!(input[:effective_on]).iso8601,
            entry_id: SavingsChallenge::Inputs.id!(input[:entry_id], nullable: true),
            expected_version_id: SavingsChallenge::Inputs.id!(input[:expected_version_id], nullable: true),
            expected_entry_lock_version: SavingsChallenge::Inputs.integer!(input.fetch(:expected_entry_lock_version, 0), minimum: 0),
            reason: SavingsChallenge::Inputs.text!(input[:reason], required: input[:expected_version_id].present?))
          HouseholdFinance::SavingsProjection.new(entries: [ {
            logical_entry_id: "entry", version_id: "draft", approval_state: "draft", current_head: false,
            effective_on: normalized[:effective_on], signed_cents: normalized[:signed_cents], currency: "USD",
            funding_source: normalized[:funding_source], evidence_supported_cents: 0
          } ], cutoff_on: normalized[:effective_on]).call
          normalized
        end

        def subject_for(input, lock:)
          enrollment_for(input, lock: lock)
        end

        def mutate!(enrollment, input, prepared:)
          date = SavingsChallenge::Inputs.date!(input[:effective_on])
          raise ArgumentError, "Savings date must be within the personal challenge window" unless (enrollment.starts_on..enrollment.ends_on).cover?(date)
          entry = if input[:entry_id]
            enrollment.savings_entries.lock.find(input[:entry_id])
          else
            check_version!(input[:expected_version_id], nil)
            check_version!(input[:expected_entry_lock_version], 0)
            enrollment.savings_entries.create!
          end
          check_version!(entry.current_approved_version_id, input[:expected_version_id])
          check_version!(entry.lock_version, input[:expected_entry_lock_version])
          raise ArgumentError, "Use an explicit zero attestation instead of a new zero contribution" if entry.current_approved_version_id.nil? && input[:signed_cents].zero?
          entry.savings_entry_drafts.create!(created_by_user: user, signed_cents: input[:signed_cents], effective_on: date,
            funding_source: input[:funding_source], base_version_id: entry.current_approved_version_id,
            base_entry_lock_version: entry.lock_version, reason: input[:reason])
        end

        def planned_record(_before, input)
          { created_by_user_id: user.id, signed_cents: input[:signed_cents], effective_on: Date.iso8601(input[:effective_on]),
            funding_source: input[:funding_source], base_version_id: input[:expected_version_id],
            base_entry_lock_version: input[:expected_entry_lock_version], reason: input[:reason], status: "pending" }
        end
      end
    end
  end
end
