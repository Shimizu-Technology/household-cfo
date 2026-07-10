module HouseholdFinance
  class MiaActionDraftApplier
    Result = Struct.new(:success?, :draft, :errors, keyword_init: true)
    StaleDraftError = Class.new(StandardError)

    def initialize(draft, user:)
      @draft = draft
      @household = draft.household
      @user = user
    end

    def call
      ApplicationRecord.transaction do
        # Canonical budget-write lock order: household first, then child rows.
        # Keep this consistent with AnnualBudgetManager and action cancelation to
        # avoid deadlocks between concurrent budget/draft operations.
        household.lock!
        draft.lock!
        raise ArgumentError, "Mia action draft is not pending" unless draft.pending?

        draft.mia_action_items.order(:position, :id).each { |item| apply_item!(item) }
        draft.update!(status: "applied", applied_by_user: user, applied_at: Time.current)
        audit!("mia_action_draft.applied")
      end

      Result.new(success?: true, draft: draft.reload, errors: [])
    rescue ActiveRecord::RecordNotUnique
      Result.new(success?: false, draft: draft, errors: [ stale_category_name_message ])
    rescue ActiveRecord::RecordInvalid => e
      Result.new(success?: false, draft: draft, errors: e.record.errors.full_messages)
    rescue ArgumentError, ActiveRecord::RecordNotFound, StaleDraftError => e
      Result.new(success?: false, draft: draft, errors: [ e.message ])
    end

    private

    attr_reader :draft, :household, :user

    def apply_item!(item)
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
      else
        raise ArgumentError, "Unsupported Mia action item"
      end
    end

    def apply_create_category!(item)
      payload = item.payload.deep_symbolize_keys
      name = payload.fetch(:name).to_s.squish
      conflicting_category = household.budget_categories.lock.find_by("LOWER(name) = ?", name.downcase)
      raise StaleDraftError, stale_category_name_message(name) if conflicting_category

      manager.create_category!(
        name: name,
        stack_key: payload.fetch(:stack_key),
        monthly_amount: Money.dollars(payload.fetch(:monthly_amount_cents).to_i)
      )
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
      proposed_name = draft.mia_action_items.find { |item| item.action_type == "create_category" }&.payload&.dig("name")
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
