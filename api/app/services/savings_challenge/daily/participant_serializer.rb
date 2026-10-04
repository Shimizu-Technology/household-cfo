module SavingsChallenge
  module Daily
    class ParticipantSerializer
      COMMON = %w[id current_version_id lock_version version_number previous_version_id approved_at reason].freeze
      PURCHASE = %w[savings_daily_purchase_id base_version_id base_head_lock_version approved_version_id status amount_cents merchant purchased_on posted_on splits link_kind linked_transaction_id canonical_digest previous_canonical_digest household_transaction_id disposition daily_sequence].freeze
      REFLECTION = %w[savings_daily_purchase_id savings_daily_reflection_id feeling_then feeling_now erased_at].freeze
      CHECK_IN = %w[savings_daily_check_in_id local_on spending_state daily_sequence].freeze
      CHECKPOINT = %w[savings_checkpoint_id milestone_day base_version_id base_head_lock_version approved_version_id status snapshot].freeze
      def self.record(record)
        raise ArgumentError, "Unsupported private daily record" unless ParticipantReader::COLLECTIONS.values.any? { |model| record.is_a?(model) }
        fields = case record
        when SavingsDailyPurchase, SavingsDailyPurchaseDraft, SavingsDailyPurchaseVersion then PURCHASE
        when SavingsDailyReflection, SavingsDailyReflectionVersion then REFLECTION
        when SavingsDailyCheckIn, SavingsDailyCheckInVersion then CHECK_IN
        when SavingsCheckpoint, SavingsCheckpointDraft, SavingsCheckpointVersion then CHECKPOINT
        end
        values = record.attributes.slice(*(COMMON + fields))
        values["current_version"] = record.current_version && self.record(record.current_version) if record.respond_to?(:current_version)
        values
      end
    end
  end
end
