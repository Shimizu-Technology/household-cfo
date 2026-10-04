module SavingsChallenge
  # Caller holds the household lock after fresh participant authorization.
  class PersonalExport
    MAX_RECORDS = 20_000
    def initialize(enrollment, include_reflections: false) = (@enrollment, @include_reflections = enrollment, include_reflections)
    def call
      savings = { entry_versions: SavingsEntryVersion, plan_versions: SavingsPlanVersion,
        zero_attestations: SavingsZeroAttestation, evidence_versions: SavingsEvidenceVersion, debt_versions: SavingsDebtVersion }
      daily = { purchase_versions: SavingsDailyPurchaseVersion, check_in_versions: SavingsDailyCheckInVersion, checkpoint_versions: SavingsCheckpointVersion }
      daily[:reflection_versions] = SavingsDailyReflectionVersion if @include_reflections
      count = (savings.values + daily.values).sum { |model| model.where(savings_enrollment: @enrollment).count }
      raise ArgumentError, "This history exceeds the supported export size; ask technical support for a private export" if count > MAX_RECORDS
      {
        schema_version: 1, captured_at: Time.current.iso8601, actor_scope: { user_id: @enrollment.user_id, household_id: @enrollment.household_id },
        enrollment: ParticipantSerializer.record(@enrollment), calendar: ParticipantSerializer.calendar(@enrollment),
        projection: Projection.new(@enrollment).call.slice(:reported_cents, :evidence_supported_cents, :reporting_known, :achieved),
        current_entries: @enrollment.savings_entries.where.not(current_approved_version_id: nil).order(:id).pluck(:id, :current_approved_version_id).map { |id, version| { id: id, current_approved_version_id: version } },
        current_debt_cards: SavingsDebtCard.where(savings_enrollment: @enrollment).where.not(current_version_id: nil).order(:id).pluck(:id, :current_version_id).map { |id, version| { id: id, current_version_id: version } },
        current_daily_records: { purchases: SavingsDailyPurchase, check_ins: SavingsDailyCheckIn, checkpoints: SavingsCheckpoint }.transform_values do |model|
          model.where(savings_enrollment: @enrollment).where.not(current_version_id: nil).order(:id).pluck(:id, :current_version_id).map { |id, version| { id: id, current_version_id: version } }
        end,
        savings: savings.transform_values { |model| model.where(savings_enrollment: @enrollment).order(:id).map { |record| savings_record(record) } },
        daily: daily.transform_values { |model| model.where(savings_enrollment: @enrollment).order(:id).map { |record| Daily::ParticipantSerializer.record(record) } },
        optional_reflections_included: @include_reflections,
        qualifications: [ "Approved versions and corrections are retained; older versions are not additional savings.",
          "Evidence-supported savings are a subset of participant-reported savings.", "Original documents, chat, pending proposals and other participants are excluded.",
          "Removing a reflection from the app cannot recall a copy already downloaded." ]
      }
    end
    private
    def savings_record(record)
      return Debt::Reader.record(record) if record.is_a?(SavingsDebtVersion)
      return record.attributes.slice("id", "savings_entry_id", "previous_version_id", "version_number", "approval_sequence", "signed_cents", "effective_on", "currency", "funding_source", "reason", "approved_at") if record.is_a?(SavingsEntryVersion)
      ParticipantSerializer.record(record)
    end
  end
end
