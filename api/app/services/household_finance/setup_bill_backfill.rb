module HouseholdFinance
  # Households set up by chat before bills were their own budget rows have one
  # "Fixed essentials" (or "Flexible spending") row, with the named bills only
  # in the applied setup card. Where that breakdown still adds up to the saved
  # row in every month, split it into one row per bill and archive the old row
  # (its history stays readable). Anything else is left exactly as it is.
  # Safe to run twice: a split household has no single row left to split.
  class SetupBillBackfill
    Result = Data.define(:household_id, :field, :action, :detail)

    def self.call(scope = Household.all, dry_run: false, logger: Rails.logger)
      scope.find_each.flat_map { |household| new(household, dry_run: dry_run, logger: logger).call }
    end

    def initialize(household, dry_run: false, logger: Rails.logger)
      @household = household
      @dry_run = dry_run
      @logger = logger
    end

    def call
      household.with_lock do
        MiaSetupCard::BILL_FIELDS.filter_map { |field| split(field) }
      end
    end

    private

    attr_reader :household, :dry_run, :logger

    def split(field)
      stack = HouseholdFieldRegistry.stack_key(field)
      items = household.expense_items.where(active: true, stack_key: stack).to_a
      return unless items.one? && MiaSetupCard::AGGREGATE_LABELS.include?(items.first.label.downcase) && items.first.cadence == "monthly"
      aggregate = items.first
      category = household.budget_categories.active.where(stack_key: stack).where("LOWER(name) = ?", aggregate.label.downcase).first
      return log(field, :skipped, "no budget row named #{aggregate.label}") unless category
      return log(field, :skipped, "#{category.name} has purchases waiting for review") if category.transaction_drafts.pending.exists?
      return log(field, :skipped, "more than one active budget row") if household.budget_categories.active.where(stack_key: stack).count > 1
      parts = breakdown(field)
      return log(field, :skipped, "no applied breakdown") unless parts
      return log(field, :skipped, "breakdown #{parts.sum { |part| part[:cents] }} does not match saved #{aggregate.amount_cents}") unless parts.sum { |part| part[:cents] } == aggregate.amount_cents
      taken = parts.map { |part| part[:name].downcase } & household.budget_categories.pluck(:name).map(&:downcase)
      return log(field, :skipped, "a budget row named #{taken.first} already exists") if taken.any?
      allocations = category.budget_allocations.to_a
      return log(field, :skipped, "a month's plan differs from the saved total") unless allocations.all? { |allocation| allocation.planned_amount_cents.in?([ 0, aggregate.amount_cents ]) }
      return log(field, :would_split, describe(category, parts)) if dry_run

      manager = AnnualBudgetManager.new(household)
      parts.each do |part|
        created = household.budget_categories.create!(name: part[:name], stack_key: stack, active: true, sort_order: household.budget_categories.maximum(:sort_order).to_i + 1)
        household.expense_items.create!(label: part[:name], stack_key: stack, amount_cents: part[:cents], cadence: "monthly", active: true)
        # Each month keeps exactly the total it had: the bill where the old row
        # had the total, nothing where it had nothing.
        allocations.each do |allocation|
          BudgetAllocation.create!(budget_period_id: allocation.budget_period_id, budget_category: created,
            planned_amount_cents: allocation.planned_amount_cents.zero? ? 0 : part[:cents], source: allocation.source)
        end
      end
      manager.archive_category_inside_household_lock!(category)
      log(field, :split, describe(category, parts))
    end

    # The latest applied setup card that named this layer's bills.
    def breakdown(field)
      household.mia_action_drafts.where(draft_type: "household_setup", status: "applied").where("mia_action_drafts.metadata ? 'setup_card'").recent_first.limit(20).each do |draft|
        parts = Array(draft.metadata.dig("setup_card", "fields", field, "parts"))
        next if parts.empty?
        return unless parts.all? { |part| part["counted"] && part["kind"].in?(%w[part remainder]) && part["cents"].to_i.positive? }
        names = parts.map { |part| part["label"].to_s.squish.truncate(80, omission: "") }
        return if names.any?(&:blank?) || names.map(&:downcase).uniq.length != names.length
        return names.zip(parts).map { |name, part| { name: name, cents: part["cents"].to_i } }
      end
      nil
    end

    def describe(category, parts) = "#{category.name} -> #{parts.map { |part| "#{part[:name]} #{part[:cents]}" }.join(', ')}"

    def log(field, action, detail)
      logger.info("[SetupBillBackfill] household=#{household.id} field=#{field} #{action}: #{detail}")
      Result.new(household_id: household.id, field: field, action: action, detail: detail)
    end
  end
end
