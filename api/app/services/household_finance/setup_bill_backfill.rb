module HouseholdFinance
  # Households set up by chat before bills were their own budget rows have one
  # "Fixed essentials" (or "Flexible spending") row, with the named bills only
  # in the applied setup card. Where that breakdown still adds up to the saved
  # row in every month, split it into one row per bill and archive the old row
  # (its history stays readable). Anything else is left exactly as it is.
  # Safe to run twice: a split household has no single row left to split.
  class SetupBillBackfill
    Result = Data.define(:household_id, :field, :action, :detail)
    # The applied card is stamped a moment after the rows it saved.
    SAME_SAVE = 5.minutes

    # One household that can't be split never stops the run: its changes roll
    # back together, the reason is logged, and the next household goes on.
    def self.call(scope = Household.all, dry_run: false, logger: Rails.logger)
      scope.find_each.flat_map do |household|
        new(household, dry_run: dry_run, logger: logger).call
      rescue StandardError => error
        detail = "#{error.class}: #{error.message}"
        logger.error("[SetupBillBackfill] household=#{household.id} error: #{detail}")
        [ Result.new(household_id: household.id, field: "all", action: :error, detail: detail) ]
      end
    end

    def initialize(household, dry_run: false, logger: Rails.logger)
      @household = household
      @dry_run = dry_run
      @logger = logger
    end

    def call
      # Results are logged only once the household's transaction has committed:
      # if a later bill field raises, every field rolls back and none of them
      # was saved, so none may read as split in the log.
      results = household.with_lock do
        MiaSetupCard::BILL_FIELDS.filter_map { |field| split(field) }
      end
      results.each { |result| logger.info("[SetupBillBackfill] household=#{household.id} field=#{result.field} #{result.action}: #{result.detail}") }
      results
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
      return log(field, :skipped, "#{category.name} has purchases waiting for review") if category.purchases_waiting?
      # A card she hasn't applied may name the row this would archive, and its
      # checks would go stale. Leave her mid-edit alone; run again later.
      return log(field, :skipped, "a review card is waiting for her") if household.mia_action_drafts.reviewable.exists?
      return log(field, :skipped, "more than one active budget row") if household.budget_categories.active.where(stack_key: stack).count > 1
      parts = breakdown(field, aggregate.updated_at)
      return log(field, :skipped, "no applied breakdown") unless parts
      return log(field, :skipped, "breakdown #{parts.sum { |part| part[:cents] }} does not match saved #{aggregate.amount_cents}") unless parts.sum { |part| part[:cents] } == aggregate.amount_cents
      taken = parts.map { |part| part[:name].downcase } & household.budget_categories.pluck(:name).map(&:downcase)
      return log(field, :skipped, "a budget row named #{taken.first} already exists") if taken.any?
      elsewhere = parts.find { |part| household.expense_items.where.not(stack_key: stack).where("LOWER(label) = ?", part[:name].downcase).exists? }
      return log(field, :skipped, "#{elsewhere[:name]} is already saved in another layer") if elsewhere
      allocations = category.budget_allocations.to_a
      return log(field, :skipped, "a month's plan differs from the saved total") unless allocations.all? { |allocation| allocation.planned_amount_cents.in?([ 0, aggregate.amount_cents ]) }
      return log(field, :would_split, describe(category, parts)) if dry_run

      # The normal budget operations do the writing, so a bill is created, and
      # the old row archived, exactly as when she does it in Budget. A same-named
      # inactive expense item is reused by them rather than colliding.
      manager = AnnualBudgetManager.new(household)
      manager.ensure_plan_inside_household_lock!
      parts.each do |part|
        created = manager.create_category_inside_household_lock!(name: part[:name], stack_key: stack, monthly_amount: Money.dollars(part[:cents]).to_s)
        # Each month keeps exactly the total it had: the bill where the old row
        # had the total, nothing where it had nothing.
        allocations.each do |allocation|
          BudgetAllocation.find_or_initialize_by(budget_period_id: allocation.budget_period_id, budget_category: created)
            .update!(planned_amount_cents: allocation.planned_amount_cents.zero? ? 0 : part[:cents], source: allocation.source)
        end
      end
      manager.archive_category_inside_household_lock!(category)
      audit(field, category, parts)
      log(field, :split, describe(category, parts))
    end

    # The latest applied setup card that named this layer's bills.
    # The saved total must have come from that card, not match it by chance:
    # the card was applied after the saved row was last written.
    def breakdown(field, saved_at)
      household.mia_action_drafts.where(draft_type: "household_setup", status: "applied").where("mia_action_drafts.metadata ? 'setup_card'").recent_first.limit(20).each do |draft|
        parts = Array(draft.metadata.dig("setup_card", "fields", field, "parts"))
        next if parts.empty?
        return unless draft.applied_at && draft.applied_at >= saved_at - SAME_SAVE
        return unless parts.all? { |part| part["counted"] && part["kind"].in?(%w[part remainder]) && part["cents"].to_i.positive? }
        names = parts.map { |part| part["label"].to_s.squish.truncate(80, omission: "") }
        return if names.any?(&:blank?) || names.map(&:downcase).uniq.length != names.length
        return names.zip(parts).map { |name, part| { name: name, cents: part["cents"].to_i } }
      end
      nil
    end

    def audit(field, category, parts)
      household.household_audit_events.create!(actor_type: "system", event_type: "setup_bills.split", auditable_type: "Household", auditable_id: household.id, occurred_at: Time.current,
        metadata: { field: field, from: category.name, to: parts.map { |part| { name: part[:name], cents: part[:cents] } } })
    end

    def describe(category, parts) = "#{category.name} -> #{parts.map { |part| "#{part[:name]} #{part[:cents]}" }.join(', ')}"

    def log(field, action, detail)
      Result.new(household_id: household.id, field: field, action: action, detail: detail)
    end
  end
end
