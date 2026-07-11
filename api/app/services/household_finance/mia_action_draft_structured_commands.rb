module HouseholdFinance
  module MiaActionDraftStructuredCommands
    private

    def structured_command_result
      command_year = command[:year].to_i
      if command_year.positive? && command_year != annual_budget_manager.year
        return validation_result("That budget action resolved to #{command_year}, but you are working in #{annual_budget_manager.year}. Nothing changed; tell me which year you mean.")
      end

      case command.fetch(:type).to_s
      when "set_allocation"
        structured_allocation_proposal(:set)
      when "increase_allocation"
        structured_allocation_proposal(:increase_by)
      when "decrease_allocation"
        structured_allocation_proposal(:decrease_by)
      when "move_allocation"
        structured_move_proposal
      when "create_category"
        structured_create_category_proposal
      when "rename_category"
        structured_rename_category_proposal
      when "reclassify_category"
        structured_reclassify_category_proposal
      when "archive_category"
        structured_archive_category_proposal
      when "restore_category"
        structured_restore_category_proposal
      when "review_pending_action"
        structured_existing_draft_result
      else
        validation_result("I could not safely resolve that budget action. Nothing changed. Please name the category, amount, and month.")
      end
    end

    def structured_allocation_proposal(mode)
      category = structured_category(active: true)
      return missing_category_result([ command[:category_name].presence || "that category" ]) unless category

      amount_cents = amount_cents_from(command[:amount])
      return validation_result("I can draft budget allocation edits only with a dollar amount of $0 or more.") if amount_cents.negative?

      month_numbers = structured_month_numbers
      return validation_result("Tell me which month or months this budget edit should affect. Nothing changed.") if month_numbers.empty?

      changes = allocation_changes_for(category, month_numbers: month_numbers, mode: mode, amount_cents: amount_cents)
      return changes if changes.is_a?(MiaActionDraftBuilder::Result)
      return no_allocation_change_result(category, changes, mode: mode, amount_cents: amount_cents, month_numbers: month_numbers) if no_allocation_change?(changes)

      item = allocation_item(category, changes, allocation_label(category, mode, amount_cents))
      scope = scope_label(month_numbers)
      proposal_result(
        title: "Edit planned budget dollars",
        summary: allocation_summary(category, mode, amount_cents, scope),
        rationale: "This changes planned budget allocations only. Actual spending does not change.",
        items: [ item ],
        metadata: { source: "mia_chat", parser: "model_intent", month_numbers: month_numbers, mode: mode }
      )
    end

    def structured_move_proposal
      from_category = structured_category(active: true)
      to_category = structured_category(active: true, target: true)
      missing = []
      missing << (command[:category_name].presence || "the source category") unless from_category
      missing << (command[:target_category_name].presence || "the destination category") unless to_category
      return missing_category_result(missing) if missing.any?
      return validation_result("Choose two different categories before I draft a budget move.") if from_category.id == to_category.id

      amount_cents = amount_cents_from(command[:amount])
      return validation_result("I can draft budget moves only with a dollar amount above $0.") unless amount_cents.positive?

      month_numbers = structured_month_numbers
      return validation_result("Tell me which month or months this budget move should affect. Nothing changed.") if month_numbers.empty?

      from_changes = allocation_changes_for(from_category, month_numbers: month_numbers, mode: :decrease_by, amount_cents: amount_cents)
      return from_changes if from_changes.is_a?(MiaActionDraftBuilder::Result)
      to_changes = allocation_changes_for(to_category, month_numbers: month_numbers, mode: :increase_by, amount_cents: amount_cents)
      return to_changes if to_changes.is_a?(MiaActionDraftBuilder::Result)

      scope = scope_label(month_numbers)
      proposal_result(
        title: "Move planned dollars between categories",
        summary: "I drafted a budget move of #{money(amount_cents)} from #{from_category.name} to #{to_category.name} for #{scope}.",
        rationale: "This changes planned budget allocations only. Actual spending stays unchanged.",
        items: [
          allocation_item(from_category, from_changes, "Reduce #{from_category.name} by #{money(amount_cents)}"),
          allocation_item(to_category, to_changes, "Increase #{to_category.name} by #{money(amount_cents)}")
        ],
        metadata: { source: "mia_chat", parser: "model_intent", month_numbers: month_numbers }
      )
    end

    def structured_create_category_proposal
      name = clean_new_category_name(command[:new_name].presence || command[:category_name])
      return validation_result("Tell me the category name before I draft a new budget row.") if name.blank?
      if (existing_category = household.budget_categories.find_by("LOWER(name) = ?", name.downcase))
        return existing_category_name_result(existing_category)
      end

      amount_cents = amount_cents_from(command[:amount].presence || "0")
      return validation_result("I can create a category only with a dollar amount of $0 or more.") if amount_cents.negative?
      month_numbers = structured_month_numbers
      return validation_result("Should this new category amount apply every month, or only specific months? Nothing changed.") if month_numbers.empty?

      stack_key = valid_stack_key(command[:stack_key]) || "discretionary"
      scope = scope_label(month_numbers)
      item = MiaActionDraftBuilder::Item.new(
        action_type: "create_category",
        label: "Create #{name} at #{money(amount_cents)} for #{scope}",
        description: "Adds a new #{stack_label(stack_key)} category with #{money(amount_cents)} planned for #{scope}.",
        target_record_type: "BudgetCategory",
        target_record_id: nil,
        payload: { name: name, stack_key: stack_key, monthly_amount_cents: amount_cents, month_numbers: month_numbers, year: annual_budget_manager.year },
        before_snapshot: {},
        after_snapshot: { name: name, stack_key: stack_key, stack_label: stack_label(stack_key), monthly_amount_cents: amount_cents, month_numbers: month_numbers }
      )
      proposal_result(
        title: "Create budget category",
        summary: "I drafted a new #{stack_label(stack_key)} category named #{name} at #{money(amount_cents)} for #{scope}.",
        rationale: "This adds planned dollars only after you apply the draft.",
        items: [ item ],
        metadata: { source: "mia_chat", parser: "model_intent", month_numbers: month_numbers }
      )
    end

    def structured_rename_category_proposal
      category = structured_category(active: true)
      return missing_category_result([ command[:category_name].presence || "that category" ]) unless category

      new_name = clean_new_category_name(command[:new_name])
      return validation_result("Tell me the new category name before I draft the rename.") if new_name.blank?
      return validation_result("#{category.name} already has that name.") if normalized_label(category.name) == normalized_label(new_name)
      return validation_result("A category named #{new_name} already exists. Rename or archive the existing category first.") if household.budget_categories.where("LOWER(name) = ?", new_name.downcase).where.not(id: category.id).exists?

      item = MiaActionDraftBuilder::Item.new(
        action_type: "update_category",
        label: "Rename #{category.name} to #{new_name}",
        description: "The category name changes. Planned and actual dollars stay in the same row.",
        target_record_type: "BudgetCategory",
        target_record_id: category.id,
        payload: { category_id: category.id, name: new_name, stack_key: category.stack_key, year: annual_budget_manager.year },
        before_snapshot: category_snapshot(category),
        after_snapshot: category_snapshot(category).merge(name: new_name)
      )
      proposal_result(
        title: "Rename budget category",
        summary: "I drafted a rename from #{category.name} to #{new_name}.",
        rationale: "This keeps the same budget row and history, but updates the label your household sees.",
        items: [ item ],
        metadata: { source: "mia_chat", parser: "model_intent" }
      )
    end

    def structured_reclassify_category_proposal
      category = structured_category(active: true)
      return missing_category_result([ command[:category_name].presence || "that category" ]) unless category

      stack_key = valid_stack_key(command[:stack_key])
      return validation_result("Tell me which Expense Stack group this category should use. Nothing changed.") unless stack_key
      return validation_result("#{category.name} is already in #{stack_label(stack_key)}.") if category.stack_key == stack_key

      item = MiaActionDraftBuilder::Item.new(
        action_type: "update_category",
        label: "Move #{category.name} to #{stack_label(stack_key)}",
        description: "The category moves from #{category.stack_label} to #{stack_label(stack_key)}. Planned and actual dollars stay attached to the category.",
        target_record_type: "BudgetCategory",
        target_record_id: category.id,
        payload: { category_id: category.id, name: category.name, stack_key: stack_key, year: annual_budget_manager.year },
        before_snapshot: category_snapshot(category),
        after_snapshot: category_snapshot(category).merge(stack_key: stack_key, stack_label: stack_label(stack_key))
      )
      proposal_result(
        title: "Reclassify budget category",
        summary: "I drafted moving #{category.name} from #{category.stack_label} to #{stack_label(stack_key)}.",
        rationale: "This changes the Expense Stack classification only. It does not change actual spending.",
        items: [ item ],
        metadata: { source: "mia_chat", parser: "model_intent" }
      )
    end

    def structured_archive_category_proposal
      category = structured_category(active: true)
      return missing_category_result([ command[:category_name].presence || "that category" ]) unless category
      return validation_result("#{category.name} has pending transaction drafts. Confirm, correct, or ignore those before archiving it.") if category.transaction_drafts.pending.exists?

      item = MiaActionDraftBuilder::Item.new(
        action_type: "archive_category",
        label: "Archive #{category.name}",
        description: "The category leaves active planning. Confirmed history remains available in reports.",
        target_record_type: "BudgetCategory",
        target_record_id: category.id,
        payload: { category_id: category.id, year: annual_budget_manager.year },
        before_snapshot: category_snapshot(category),
        after_snapshot: category_snapshot(category).merge(active: false)
      )
      proposal_result(
        title: "Archive budget category",
        summary: "I drafted archiving #{category.name}.",
        rationale: "Archiving removes the row from active planning but does not delete transaction history.",
        items: [ item ],
        metadata: { source: "mia_chat", parser: "model_intent" }
      )
    end

    def structured_restore_category_proposal
      category = structured_category(active: false)
      return missing_category_result([ command[:category_name].presence || "that category" ], active: false) unless category

      item = MiaActionDraftBuilder::Item.new(
        action_type: "restore_category",
        label: "Restore #{category.name}",
        description: "The category returns to the active annual budget view.",
        target_record_type: "BudgetCategory",
        target_record_id: category.id,
        payload: { category_id: category.id, year: annual_budget_manager.year },
        before_snapshot: category_snapshot(category),
        after_snapshot: category_snapshot(category).merge(active: true)
      )
      proposal_result(
        title: "Restore budget category",
        summary: "I drafted restoring #{category.name} to the active budget.",
        rationale: "Restoring brings the category back for planning; it does not create actual spending.",
        items: [ item ],
        metadata: { source: "mia_chat", parser: "model_intent" }
      )
    end

    def structured_existing_draft_result
      draft = household.mia_action_drafts.pending.find_by(id: command[:draft_id].to_i)
      return validation_result("I could not find that pending budget review. Nothing changed; ask me to prepare the edit again.") unless draft

      MiaActionDraftBuilder::Result.new(
        proposal: nil,
        existing_draft: draft,
        annual_plan: annual_plan,
        response: "That budget review card is ready below. Use Apply to make the change, or Cancel to leave the budget as it is. Nothing else changed."
      )
    end

    def structured_category(active:, target: false)
      id_key = target ? :target_category_id : :category_id
      name_key = target ? :target_category_name : :category_name
      scope = active ? household.budget_categories.active : household.budget_categories.archived
      category_id = command[id_key].to_i
      return scope.find_by(id: category_id) if category_id.positive?

      name = command[name_key].to_s.squish
      return if name.blank?

      scope.where("LOWER(name) = ?", name.downcase).first
    end

    def structured_month_numbers
      Array(command[:months]).map(&:to_i).select { |month| month.between?(1, 12) }.uniq.sort
    end

    def valid_stack_key(value)
      value.to_s if BudgetCategory::STACK_KEYS.include?(value.to_s)
    end
  end
end
