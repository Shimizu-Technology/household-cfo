module SavingsChallenge
  # A reviewed spending experiment is an estimate, never saved-money evidence.
  class PlanContext
    def initialize(enrollment, user:) = (@enrollment, @user = enrollment, user)

    def normalize(input)
      id = Inputs.id!(input[:financial_baseline_version_id], nullable: true)
      digest = input[:baseline_digest]
      raise ArgumentError, "Review an exact baseline identity and digest together" unless id ? digest.is_a?(String) && digest.match?(/\A[0-9a-f]{64}\z/) : digest.nil?
      changes = input.fetch(:spending_changes, [])
      raise ArgumentError, "Choose at most five comfortable spending changes" unless changes.is_a?(Array) && changes.length <= 5
      changes = changes.map do |raw|
        raw = raw.to_h.deep_symbolize_keys
        Inputs.keys!(raw, required: %i[budget_category_id description recurrence planned_reduction_cents])
        raise ArgumentError, "Choose the change's recurrence assumption" unless FinancialBaselines::Request::RECURRENCES.include?(raw[:recurrence])
        { budget_category_id: Inputs.id!(raw[:budget_category_id], nullable: true), description: Inputs.text!(raw[:description], required: true),
          recurrence: raw[:recurrence], planned_reduction_cents: Inputs.money!(raw[:planned_reduction_cents], nullable: true, positive: true) }
      end
      raise ArgumentError, "Choose each spending change once" unless changes.map { |row| [ row[:budget_category_id], row[:description].downcase ] }.uniq.length == changes.length
      { financial_baseline_version_id: id, baseline_digest: digest, spending_changes: changes.map(&:deep_stringify_keys) }
    end

    def validate!(values)
      id = values[:financial_baseline_version_id]
      baseline = if id
        state = FinancialBaselines::Reader.new(@enrollment.household, user: @user).current
        version = state[:approved_version]
        unless version&.id == id && version.digest == values[:baseline_digest] && !state[:needs_revision]
          raise HouseholdFinance::Operations::Base::StaleOperation, "The approved baseline changed. Review the current spending window before accepting this plan."
        end
        version
      end
      values[:spending_changes].each do |change|
        id = change["budget_category_id"]
        next unless id
        category = @enrollment.household.budget_categories.active.find(id)
        raise ArgumentError, "Choose a specific category" if category.name.match?(/\A(?:uncategorized|needs category)\z/i)
        next unless baseline
        eligible = baseline.snapshot.fetch("category_eligibility").any? { |row| row["budget_category_id"] == id && row["eligible"] == true }
        raise ArgumentError, "Only participant-approved eligible categories can be proposed from this baseline" unless eligible
      end
      true
    end
  end
end
