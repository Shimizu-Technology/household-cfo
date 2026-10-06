module HouseholdFinance
  class MiaActionPlanBuilder
    MAX_ACTIONS = 12
    BUDGET_ACTION_TYPES = %w[
      set_allocation increase_allocation decrease_allocation move_allocation
      create_category rename_category reclassify_category archive_category restore_category
    ].freeze
    YEAR_DEPENDENT_OPERATION_KEYS = %w[
      budget.category.create budget.category.update budget.category.archive budget.category.restore budget.allocation.set
      income.schedule.create income.schedule.update income.schedule.delete
    ].freeze

    def initialize(household, user:, annual_budget_manager:, selected_month:, raw_input:, actions:)
      @household = household
      @user = user
      @annual_budget_manager = annual_budget_manager
      @selected_month = selected_month
      @raw_input = raw_input.to_s
      @actions = Array(actions)
    end

    def call
      return validation("Tell me at least one household change to prepare. Nothing changed.") if actions.empty?
      return validation("I can prepare up to #{MAX_ACTIONS} changes in one review. Split this request into smaller plans. Nothing changed.") if actions.length > MAX_ACTIONS

      normalized = normalize_actions
      return normalized if normalized.is_a?(MiaActionDraftBuilder::Result)
      incompatible_budget_years = normalized.filter_map do |entry|
        action = entry.fetch(:action)
        next unless action[:type].to_s.in?(BUDGET_ACTION_TYPES)

        year = action[:year].to_i
        year.positive? ? year : annual_budget_manager.year
      end.uniq - [ annual_budget_manager.year ]
      if incompatible_budget_years.any?
        return validation(
          "One ordered plan can change only the budget year you are viewing (#{annual_budget_manager.year}). " \
          "Review changes for #{incompatible_budget_years.sort.to_sentence} separately. Nothing changed."
        )
      end

      results = normalized.map do |entry|
        action = entry.fetch(:action)
        year = action[:year].to_i
        manager = year.positive? && year != annual_budget_manager.year ? AnnualBudgetManager.new(household, year: year) : annual_budget_manager
        MiaActionDraftBuilder.new(
          household,
          user: user,
          annual_budget_manager: manager,
          selected_month: selected_month,
          raw_input: entry.fetch(:source_text),
          command: action
        ).call
      end
      invalid = results.find { |result| result.nil? || result.proposal.nil? }
      return invalid || validation("I could not safely prepare every requested change, so I did not create a partial plan.") if invalid

      combined_items = []
      combined_action_indexes = []
      action_positions = []
      results.each_with_index do |result, action_index|
        entry = normalized.fetch(action_index)
        local_positions = []
        result.proposal.items.each do |item|
          position = combined_items.length
          inherited = Array(item.dependencies).map { |local| local_positions.fetch(local) }
          action_dependencies = entry.fetch(:depends_on).flat_map { |index| action_positions.fetch(index) }
          dependencies = (inherited + action_dependencies).uniq.sort
          combined_items << item.dup.tap do |copy|
            copy.source_text = entry.fetch(:source_text)
            copy.source_start = entry.fetch(:source_start)
            copy.source_end = entry.fetch(:source_end)
            copy.dependencies = dependencies
          end
          combined_action_indexes << action_index
          local_positions << position
        end
        action_positions << local_positions
      end
      return validation("This plan expands to more than #{MAX_ACTIONS} review steps. Split it into smaller plans. Nothing changed.") if combined_items.length > MAX_ACTIONS
      return validation("Two requested changes target the same saved record. Ask for one change at a time and review it before requesting the next one. Nothing changed.") if conflicting_targets?(combined_items, combined_action_indexes)

      proposal = MiaActionDraftBuilder::Proposal.new(
        household: household,
        user: user,
        year: annual_budget_manager.year,
        draft_type: "action_plan",
        title: "Review #{combined_items.length} household changes",
        summary: "I prepared an ordered plan from #{actions.length} parts of your request. Apply all, or select a dependency-safe subset.",
        rationale: "Every selected change is rechecked against the latest approved household data, then applied together or not at all.",
        source_prompt: raw_input,
        items: combined_items,
        metadata: {
          source: "mia_chat",
          parser: "compound_action_plan",
          schema_version: 1,
          action_count: actions.length,
          item_count: combined_items.length
        }
      )
      MiaActionDraftBuilder::Result.new(
        proposal: proposal,
        response: proposal.summary,
        annual_plan: annual_budget_manager.plan_data,
        existing_draft: nil
      )
    rescue KeyError, ArgumentError => e
      validation("I could not safely prepare that ordered plan: #{e.message}. Nothing changed.")
    end

    private

    attr_reader :household, :user, :annual_budget_manager, :selected_month, :raw_input, :actions

    def normalize_actions
      cursor = 0
      seen = {}
      actions.each_with_index.map do |raw, index|
        entry = raw.to_h.deep_symbolize_keys
        action = entry.fetch(:action, entry.except(:source_text, :depends_on)).to_h.deep_symbolize_keys
        source = entry.fetch(:source_text).to_s
        return validation("Each planned change must quote the exact part of your message it came from. Nothing changed.") if source.blank?
        start = raw_input.index(source, cursor)
        return validation("One planned change did not match your exact message text. Nothing changed.") unless start
        normalized_source = source.unicode_normalize(:nfkc).squish.downcase
        return validation("The same part of your message cannot create two separate changes. Nothing changed.") if seen[normalized_source]
        seen[normalized_source] = true
        cursor = start + source.length
        dependencies = Array(entry[:depends_on]).map { |value| Integer(value) }.uniq.sort
        unless dependencies.all? { |dependency| dependency >= 0 && dependency < index }
          return validation("Plan dependencies must point only to earlier requested changes. Nothing changed.")
        end
        { action: action, source_text: source, source_start: start, source_end: start + source.length, depends_on: dependencies }
      end
    end

    def conflicting_targets?(items, action_indexes)
      targets = items.each_with_index.filter_map do |item, index|
        next unless item.target_record_type.present? && item.target_record_id.present?
        next if item.action_type == "confirm_household_setup"

        [ [ item.target_record_type, item.target_record_id ], action_indexes.fetch(index) ]
      end
      targets.group_by(&:first).any? { |_target, entries| entries.map(&:last).uniq.many? }
    end

    def validation(message)
      MiaActionDraftBuilder::Result.new(
        proposal: nil,
        response: message,
        annual_plan: annual_budget_manager.plan_data,
        existing_draft: nil
      )
    end
  end
end
