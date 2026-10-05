module HouseholdFinance
  class MiaActionDraftApplier
    Result = Struct.new(:success?, :draft, :application, :errors, :replayed?, :conflict?, keyword_init: true)
    StaleDraftError = Class.new(StandardError)
    INCOMPLETE_DRAFT_MESSAGE = "Mia’s review card is incomplete. Ask Mia to draft a fresh edit. Nothing changed."

    def initialize(draft, user:, cohort_membership: nil)
      @draft = draft
      @household = draft.household
      @user = user
      @cohort_membership = cohort_membership
    end

    def call(idempotency_key: nil, selected_item_ids: nil)
      key = normalized_application_key(idempotency_key)
      selected_ids = normalized_selected_item_ids(selected_item_ids)
      request_fingerprint = application_fingerprint(key, selected_ids)
      application = nil

      ApplicationRecord.transaction do
        # Canonical budget-write lock order: household first, then child rows.
        # Keep this consistent with AnnualBudgetManager and action cancelation to
        # avoid deadlocks between concurrent budget/draft operations.
        household.lock!
        draft.lock!
        ensure_actor_membership!
        ::Mia::ActionDraftScope.authorize!(draft, user: user, membership: @cohort_membership)
        existing = household.mia_action_draft_applications.find_by(user: user, idempotency_key: key)
        return replay_application(existing, request_fingerprint) if existing
        raise ArgumentError, "Mia action draft is no longer available for review" unless draft.reviewable?

        items = draft.mia_action_items.lock.order(:position, :id).to_a
        selected = selected_items(items, selected_ids)
        validate_partial_selection!(items, selected, selected_ids)
        validate_dependencies!(items, selected)
        application = household.mia_action_draft_applications.create!(
          mia_action_draft: draft,
          user: user,
          idempotency_key: key,
          request_kind: "apply",
          request_fingerprint: request_fingerprint,
          selected_item_ids: selected.map(&:id)
        )

        selected.each do |item|
          @application_item_key = draft.draft_type == "action_plan" ? "mia-action-application:#{application.id}:item:#{item.id}" : "mia-action-item:#{item.id}"
          apply_item!(item)
          item.update!(applied_at: Time.current)
        end
        all_applied = items.all? { |item| item.applied_at.present? || selected.include?(item) }
        status = all_applied ? "applied" : "partially_applied"
        draft.update!(
          status: status,
          applied_by_user: user,
          applied_at: all_applied ? Time.current : nil
        )
        audit!(all_applied ? "mia_action_draft.applied" : "mia_action_draft.partially_applied") unless selected.all? { |item| registered_operation?(item) }
        application.update!(
          status: "completed",
          completed_at: Time.current,
          response_payload: { draft_id: draft.id, draft_status: status, selected_item_ids: selected.map(&:id) }
        )
      end

      Result.new(success?: true, draft: draft.reload, application: application.reload, errors: [], replayed?: false)
    rescue ActiveRecord::RecordNotUnique
      Result.new(success?: false, draft: draft, application: nil, errors: [ stale_category_name_message ])
    rescue ActiveRecord::RecordInvalid => e
      Result.new(success?: false, draft: draft, application: nil, errors: e.record.errors.full_messages)
    rescue KeyError
      Result.new(success?: false, draft: draft, application: nil, errors: [ INCOMPLETE_DRAFT_MESSAGE ])
    rescue Operations::Runner::IdempotencyConflict => e
      Result.new(success?: false, draft: draft, application: nil, errors: [ e.message ], conflict?: true)
    rescue ArgumentError, ActiveRecord::RecordNotFound, StaleDraftError,
      Operations::Base::StaleOperation => e
      Result.new(success?: false, draft: draft, application: nil, errors: [ e.message ])
    end

    private

    attr_reader :draft, :household, :user

    def normalized_application_key(value)
      key = value.to_s.strip.presence || "legacy-mia-action:#{draft.id}:#{user.id}"
      raise ArgumentError, "Idempotency key is too long" if key.length > 200
      key
    end

    def normalized_selected_item_ids(values)
      return nil if values.nil?

      ids = Array(values).map { |value| Integer(value) }
      raise ArgumentError, "Select at least one review step" if ids.empty?
      raise ArgumentError, "Review step IDs must be unique positive integers" unless ids.all?(&:positive?) && ids.uniq.length == ids.length
      ids.sort
    rescue TypeError, ArgumentError => e
      raise e if e.message.start_with?("Select", "Review")

      raise ArgumentError, "Review step IDs must be positive integers"
    end

    def application_fingerprint(key, selected_ids)
      Digest::SHA256.hexdigest(
        { household_id: household.id, draft_id: draft.id, user_id: user.id, selected_item_ids: selected_ids || "remaining" }.to_json
      )
    end

    def replay_application(application, fingerprint)
      unless secure_equal?(application.request_fingerprint, fingerprint)
        raise Operations::Runner::IdempotencyConflict, "That idempotency key was already used for a different Mia plan selection. Nothing changed."
      end
      unless application.status == "completed"
        raise ArgumentError, "That Mia plan application is still processing. Try again shortly."
      end

      Result.new(success?: true, draft: draft.reload, application: application, errors: [], replayed?: true)
    end

    def selected_items(items, selected_ids)
      available = items.reject { |item| item.applied_at.present? || item.canceled_at.present? }
      return available if selected_ids.nil?

      selected = available.select { |item| selected_ids.include?(item.id) }
      raise ActiveRecord::RecordNotFound, "One or more selected review steps are unavailable" unless selected.length == selected_ids.length
      selected
    end

    def validate_dependencies!(items, selected)
      applied_positions = items.select { |item| item.applied_at.present? }.map(&:position)
      selected_positions = selected.map(&:position)
      selected.each do |item|
        missing = Array(item.dependencies) - applied_positions - selected_positions
        next if missing.empty?

        raise ArgumentError, "Select the earlier required review steps before applying #{item.label}. Nothing changed."
      end
    end

    def validate_partial_selection!(items, selected, selected_ids)
      return if selected_ids.nil?

      unless draft.draft_type == "action_plan"
        raise ArgumentError, "Only household action plans support choosing individual review steps. Nothing changed."
      end

      remaining = items.reject { |item| item.applied_at.present? || item.canceled_at.present? }
      return unless remaining.any? { |item| item.action_type == "confirm_household_setup" }
      return if selected.length == remaining.length

      raise ArgumentError, "Starting-picture confirmations must be applied with every remaining step in this plan. Nothing changed."
    end

    def ensure_actor_membership!
      membership = household.household_memberships.lock.find_by(user_id: user.id)
      return if membership&.role.in?(%w[owner partner])

      raise ArgumentError, "You no longer have permission to change this household. Nothing changed."
    end

    def secure_equal?(left, right)
      left.bytesize == right.bytesize && ActiveSupport::SecurityUtils.secure_compare(left, right)
    end

    def apply_item!(item)
      return apply_registered_operation!(item) if operation_identity_present?(item)

      case item.action_type
      when "create_category"
        apply_create_category!(item)
      when "update_category"
        apply_update_category!(item)
      when "update_allocation"
        apply_update_allocation!(item)
      when "archive_category"
        apply_archive_category!(item)
      when "restore_category"
        apply_restore_category!(item)
      when "update_setup_value"
        apply_setup_value!(item)
      when "upsert_income_schedule_entry"
        apply_income_schedule_entry!(item)
      else
        raise ArgumentError, "Unsupported Mia action item"
      end
    end

    def operation_identity_present?(item)
      values = [ item.operation_key, item.operation_version, item.prepared_operation_fingerprint ]
      return false if values.all?(&:blank?) && item.prepared_operation.blank?
      if values.any?(&:blank?) || item.prepared_operation.blank?
        raise KeyError, "incomplete prepared operation"
      end

      true
    end

    def registered_operation?(item)
      item.operation_key.present? && item.operation_version.present? && item.prepared_operation_fingerprint.present? && item.prepared_operation.present?
    end

    def apply_registered_operation!(item)
      expected_key = Operations::MiaItemAdapter.operation_key(item)
      prepared = Operations::PreparedOperation.from_hash(item.prepared_operation)
      unless expected_key == item.operation_key &&
          prepared.operation_key == item.operation_key &&
          prepared.operation_version.to_i == item.operation_version.to_i &&
          Operations::MiaItemAdapter.normalized_input(household, item, year: draft.year) == prepared.normalized_input
        raise KeyError, "mismatched prepared operation"
      end

      Operations::Runner.new(household, user: user, cohort_membership: @cohort_membership).run_prepared(
        prepared: item.prepared_operation,
        prepared_fingerprint: item.prepared_operation_fingerprint,
        idempotency_key: @application_item_key || "mia-action-item:#{item.id}",
        source: "mia",
        reviewable: item
      )
    rescue Operations::Runner::InvalidPreparedOperation, Operations::Registry::UnknownOperation
      raise KeyError, "invalid prepared operation"
    end

    def apply_create_category!(item)
      payload = item.payload.deep_symbolize_keys
      name = payload.fetch(:name).to_s.squish
      conflicting_category = household.budget_categories.lock.find_by("LOWER(name) = ?", name.downcase)
      raise StaleDraftError, stale_category_name_message(name) if conflicting_category

      amount_cents = payload.fetch(:monthly_amount_cents).to_i
      month_numbers = Array(payload[:month_numbers]).map(&:to_i).select { |month| month.between?(1, 12) }.uniq.sort
      month_numbers = (1..12).to_a if month_numbers.empty? # Backward compatibility for pending drafts created before month scoping.
      full_year = month_numbers == (1..12).to_a
      category = manager.create_category!(
        name: name,
        stack_key: payload.fetch(:stack_key),
        monthly_amount: Money.dollars(full_year ? amount_cents : 0)
      )
      apply_created_category_months!(category, month_numbers, amount_cents) unless full_year || amount_cents.zero?
    end

    def apply_created_category_months!(category, month_numbers, amount_cents)
      starts_on = month_numbers.map { |month| Date.new(draft.year, month, 1) }
      allocations = category.budget_allocations
        .joins(:budget_period)
        .where(budget_periods: { starts_on: starts_on })
        .lock
        .to_a
      raise ActiveRecord::RecordNotFound, "Budget allocation not found" unless allocations.length == month_numbers.length

      allocations.each { |allocation| manager.update_allocation!(allocation, Money.dollars(amount_cents)) }
    end

    def apply_update_category!(item)
      payload = item.payload.deep_symbolize_keys
      category = household.budget_categories.lock.find(payload.fetch(:category_id))
      before = item.before_snapshot.deep_symbolize_keys
      if before[:name].present? && category.name != before[:name]
        raise StaleDraftError, "Budget changed since Mia drafted this. Ask Mia to draft a fresh edit."
      end
      if before[:stack_key].present? && category.stack_key != before[:stack_key]
        raise StaleDraftError, "Budget changed since Mia drafted this. Ask Mia to draft a fresh edit."
      end
      if before.key?(:active) && category.active != before[:active]
        raise StaleDraftError, "Budget changed since Mia drafted this. Ask Mia to draft a fresh edit."
      end

      proposed_name = payload[:name].to_s.squish
      if proposed_name.present?
        conflicting_category = household.budget_categories.lock
          .where("LOWER(name) = ?", proposed_name.downcase)
          .where.not(id: category.id)
          .first
        raise StaleDraftError, stale_category_name_message(proposed_name) if conflicting_category
      end

      manager.update_category!(category, name: payload[:name], stack_key: payload[:stack_key])
    end

    def apply_update_allocation!(item)
      payload = item.payload.deep_symbolize_keys
      category_id = payload.fetch(:category_id).to_i
      category = household.budget_categories.lock.find(category_id)
      unless category.active?
        raise StaleDraftError, "Budget changed since Mia drafted this. Ask Mia to draft a fresh edit."
      end

      changes = Array(payload.fetch(:changes)).map(&:deep_symbolize_keys)
      allocations_by_id = scoped_allocation_scope
        .lock
        .where(id: changes.map { |change| change.fetch(:allocation_id).to_i })
        .index_by(&:id)

      changes.each do |change|
        allocation = allocations_by_id.fetch(change.fetch(:allocation_id).to_i) { raise ActiveRecord::RecordNotFound, "Budget allocation not found" }
        unless allocation.budget_category_id == category_id && allocation.budget_period.budget_year.year == draft.year
          raise ActiveRecord::RecordNotFound, "Budget allocation not found"
        end
        if allocation.planned_amount_cents != change.fetch(:before_cents).to_i
          raise StaleDraftError, "Budget changed since Mia drafted this. Ask Mia to draft a fresh edit."
        end

        allocation.update!(planned_amount_cents: change.fetch(:after_cents).to_i, source: "manual")
      end
    end

    def apply_archive_category!(item)
      payload = item.payload.deep_symbolize_keys
      category = household.budget_categories.active.lock.find(payload.fetch(:category_id))
      ensure_category_still_matches!(category, item.before_snapshot.deep_symbolize_keys)
      manager.archive_category!(category)
    end

    def apply_restore_category!(item)
      payload = item.payload.deep_symbolize_keys
      category = household.budget_categories.archived.lock.find(payload.fetch(:category_id))
      ensure_category_still_matches!(category, item.before_snapshot.deep_symbolize_keys)
      manager.restore_category!(category)
    end

    def apply_setup_value!(item)
      payload = item.payload.deep_symbolize_keys
      key = payload.fetch(:key).to_sym
      unless MiaActionDraftHouseholdCommands::SETUP_KEYS.include?(key)
        raise ArgumentError, "Unsupported household setup field"
      end

      before = item.before_snapshot.deep_symbolize_keys.fetch(:value)
      current = DataPresenter.new(household, user: user).setup_values.fetch(key)
      unless comparable_setup_value(key, current) == comparable_setup_value(key, before)
        raise StaleDraftError, "Household numbers changed since Mia prepared this review. Ask Mia to draft a fresh update."
      end

      SetupUpdater.new(household, key => payload.fetch(:value)).call
    end

    def apply_income_schedule_entry!(item)
      payload = item.payload.deep_symbolize_keys
      before = item.before_snapshot.deep_symbolize_keys
      source = household.income_sources.where(active: true).lock.find(payload.fetch(:income_source_id))
      if source.label != payload.fetch(:income_source_label)
        raise StaleDraftError, "The income source changed since Mia prepared this review. Ask Mia to draft a fresh update."
      end

      effective_on = Date.iso8601(payload.fetch(:effective_on)).beginning_of_month
      entry_type = payload.fetch(:entry_type)
      reviewed_schedule = Array(before.fetch(:recurring_schedule_entries)).map(&:deep_symbolize_keys)
      current_schedule = MiaActionDraftHouseholdCommands.recurring_schedule_snapshot(source, effective_on)
      unless source.amount_cents == before.fetch(:income_source_amount_cents).to_i &&
          source.cadence == before.fetch(:income_source_cadence) &&
          current_schedule == reviewed_schedule
        raise StaleDraftError, "The income timeline changed since Mia prepared this review. Ask Mia to draft a fresh update."
      end

      effective_monthly_cents = IncomeTimeline.recurring_monthly_cents(source, on: effective_on)
      unless effective_monthly_cents == before.fetch(:effective_monthly_cents).to_i
        raise StaleDraftError, "The effective income changed since Mia prepared this review. Ask Mia to draft a fresh update."
      end

      entry_id = payload[:entry_id].to_i
      entry = entry_id.positive? ? source.income_schedule_entries.lock.find(entry_id) : nil
      if entry
        unless entry.effective_on == effective_on && entry.amount_cents == before[:amount_cents].to_i && entry.cadence == before[:cadence]
          raise StaleDraftError, "The income timeline changed since Mia prepared this review. Ask Mia to draft a fresh update."
        end
      elsif entry_type == "recurring_change" && source.income_schedule_entries.lock.exists?(effective_on: effective_on)
        raise StaleDraftError, "An income change now exists for that month. Ask Mia to draft a fresh update."
      end

      attributes = {
        entry_type: entry_type,
        label: payload[:label].to_s.squish.presence,
        amount_cents: payload.fetch(:amount_cents).to_i,
        cadence: payload.fetch(:cadence),
        effective_on: effective_on
      }
      entry ? entry.update!(attributes) : source.income_schedule_entries.create!(attributes)
    rescue Date::Error
      raise ArgumentError, "Income schedule date must be valid"
    end

    def comparable_setup_value(key, value)
      return value.to_f if MiaActionDraftHouseholdCommands::SETUP_MONEY_KEYS.include?(key) || key == :target_runway_months

      value.to_s.squish
    end

    def ensure_category_still_matches!(category, before)
      return if before.blank?
      return if category.name == before[:name] && category.stack_key == before[:stack_key] && category.active == before[:active]

      raise StaleDraftError, "Budget changed since Mia drafted this. Ask Mia to draft a fresh edit."
    end

    def scoped_allocation_scope
      BudgetAllocation
        .includes(:budget_category, budget_period: :budget_year)
        .joins(:budget_category, budget_period: :budget_year)
        .where(budget_categories: { household_id: household.id }, budget_years: { household_id: household.id })
    end

    def stale_category_name_message(name = nil)
      proposed_name = draft.mia_action_items.find { |item| item.action_type.in?(%w[create_category update_category]) }&.payload&.dig("name")
      label = name.to_s.squish.presence || proposed_name.to_s.squish.presence || "that name"
      "A budget category named #{label} now exists. Ask Mia to draft a fresh edit for the existing category. Nothing changed."
    end

    def manager
      @manager ||= AnnualBudgetManager.new(household, year: draft.year)
    end

    def audit!(event_type)
      household.household_audit_events.create!(
        user: user,
        actor_type: "user",
        event_type: event_type,
        auditable_type: "MiaActionDraft",
        auditable_id: draft.id,
        occurred_at: Time.current,
        metadata: {
          draft_id: draft.id,
          draft_type: draft.draft_type,
          title: draft.title,
          item_count: draft.mia_action_items.size,
          items: draft.mia_action_items.map do |item|
            {
              id: item.id,
              action_type: item.action_type,
              label: item.label,
              before_snapshot: item.before_snapshot,
              after_snapshot: item.after_snapshot
            }
          end
        }
      )
    end
  end
end
