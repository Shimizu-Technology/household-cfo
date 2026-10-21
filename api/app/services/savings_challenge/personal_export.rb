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
        daily: daily.transform_values { |model| model.where(savings_enrollment: @enrollment).order(:id).map { |record| daily_record(record) } },
        optional_reflections_included: @include_reflections,
        # Plain words: this list is shown to the participant with their downloaded record.
        qualifications: [ "Earlier versions are kept when you fix a record. They aren't extra savings.",
          "Money matched to a statement is part of what you set aside, not added to it.",
          "Statements, chat, anything you haven't confirmed, and other people's records are left out.",
          "Removing a feeling from the app can't recall a copy you already downloaded." ]
      }
    end
    private
    # Check-in versions don't store their own day; carry it so a readable copy can say which day each one was.
    def daily_record(record)
      values = Daily::ParticipantSerializer.record(record)
      if record.is_a?(SavingsDailyCheckInVersion)
        @check_in_days ||= SavingsDailyCheckIn.where(savings_enrollment: @enrollment).pluck(:id, :local_on).to_h
        values["local_on"] = @check_in_days[record.savings_daily_check_in_id]&.iso8601
      end
      values
    end
    def savings_record(record)
      return Debt::Reader.record(record) if record.is_a?(SavingsDebtVersion)
      return record.attributes.slice("id", "savings_entry_id", "previous_version_id", "version_number", "approval_sequence", "signed_cents", "effective_on", "currency", "funding_source", "reason", "approved_at") if record.is_a?(SavingsEntryVersion)
      ParticipantSerializer.record(record)
    end
  end
end
