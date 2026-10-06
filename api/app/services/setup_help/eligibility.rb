module SetupHelp
  class Eligibility
    AUTO_GOAL = "Build a clear monthly money rhythm.".freeze
    FINANCIAL_CONFIRMATIONS = (HouseholdFinance::SetupUpdater::INPUT_KEYS.map(&:to_s) - [ "household_name" ]).freeze
    FACTS = %i[income_sources expense_items debts accounts goals budget_categories household_transactions merchant_category_rules].freeze
    CHALLENGE_VERSIONS = [ SavingsPlanVersion, SavingsEntryVersion, SavingsEvidenceVersion, SavingsZeroAttestation,
      SavingsDailyCheckInVersion, SavingsDailyPurchaseVersion, SavingsDailyReflectionVersion, SavingsDebtVersion, SavingsCheckpointVersion ].freeze

    def initialize(household) = (@household = household)

    def blockers
      values = []
      values << { code: "setup_complete", label: "Your starting setup has been saved" } if HouseholdFinance::SetupStatus.new(@household).complete?
      values << { code: "saved_financial_records", label: "You have saved financial information, including any confirmed zero amounts" } if financial_facts?
      values << { code: "approved_source_records", label: "You have approved a statement or spending baseline" } if approved_sources?
      values << { code: "approved_challenge_activity", label: "You have approved challenge activity that must remain in your history" } if challenge_versions.any? { |_name, ids| ids.any? }
      values
    end

    def available? = blockers.empty?

    # Identity-only state never leaves the private participant restart review.
    def snapshot
      { blockers: blockers.map { |item| item[:code] },
        challenge_versions: challenge_versions,
        approved_baselines: FinancialBaselineHead.where(household: @household).order(:id).pluck(:id, :approved_version_id),
        approved_sources: SourceRevisionApproval.where(household: @household).order(:id).pluck(:id),
        source_heads: SourceReviewHead.where(household: @household).where.not(approved_version_id: nil).order(:id).pluck(:id, :approved_version_id),
        account_heads: SourceAccountReviewHead.where(household: @household).where.not(approved_version_id: nil).order(:id).pluck(:id, :approved_version_id),
        tracked_accounts: SourceTrackedAccount.current_picture.where(household: @household).order(:id).pluck(:id),
        members: @household.users.order(:id).pluck(:id, :role, :invitation_status),
        participant_programs: CohortMembership.where(user_id: @household.users.select(:id)).order(:id).pluck(:id, :user_id, :cohort_id, :role, :created_at) }
    end

    private

    def financial_facts?
      confirmations = Array(@household.confirmed_setup_fields) & FINANCIAL_CONFIRMATIONS
      profile = @household.household_profile
      confirmations.any? || FACTS.any? { |key| @household.public_send(key).exists? } ||
        (@household.primary_goal.present? && @household.primary_goal != AUTO_GOAL) ||
        profile.debt_summary_balance_known? || profile.debt_summary_minimum_payment_known? ||
        profile.attributes.slice("primary_decision", "household_stage", "money_stress_level", "notes").values.any?(&:present?)
    end

    def approved_sources?
      FinancialBaselineHead.where(household: @household).where.not(approved_version_id: nil).exists? ||
        SourceRevisionApproval.where(household: @household).exists? || SourceTrackedAccount.current_picture.where(household: @household).exists? ||
        SourceReviewHead.where(household: @household).where.not(approved_version_id: nil).exists? ||
        SourceAccountReviewHead.where(household: @household).where.not(approved_version_id: nil).exists?
    end

    def challenge_versions
      enrollments = SavingsEnrollment.where(household: @household).select(:id)
      CHALLENGE_VERSIONS.index_with { |model| model.where(savings_enrollment_id: enrollments).order(:id).pluck(:id) }.transform_keys(&:name)
    end
  end
end
