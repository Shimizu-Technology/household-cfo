module HouseholdFinance
  class MiaActionDraftBuilder
    include MiaActionDraftStructuredCommands

    MONEY_PATTERN = /\$?\s*\d[\d,]*(?:\.\d{1,2})?/.freeze
    ACTION_TERMS = /\b(set|change|update|adjust|make|increase|raise|decrease|lower|reduce|move|transfer|shift|add|create|rename|reclassify|recategorize|archive|delete|remove|restore)\b/i
    BUDGET_CONTEXT_TERMS = /\b(budget|category|categories|planned|plan|allocation|monthly|per month|expense stack|line item|row)\b/i
    ALL_YEAR_TERMS = /\b(all year|every month|for the year|annual(?:ly)?)\b/i
    STACK_LABELS = SnapshotBuilder::STACK_LABELS

    Result = Struct.new(:proposal, :response, :annual_plan, :existing_draft, keyword_init: true)
    Item = Struct.new(:action_type, :label, :description, :payload, :before_snapshot, :after_snapshot, :target_record_type, :target_record_id, keyword_init: true)

    class Proposal
      attr_reader :household, :user, :year, :title, :summary, :rationale, :source_prompt, :items, :metadata

      def initialize(household:, user:, year:, title:, summary:, rationale:, source_prompt:, items:, metadata: {})
        @household = household
        @user = user
        @year = year
        @title = title
        @summary = summary
        @rationale = rationale
        @source_prompt = source_prompt
        @items = items
        @metadata = metadata
      end

      def create_draft!(source_chat_message:, assistant_chat_message:)
        ApplicationRecord.transaction do
          draft = household.mia_action_drafts.create!(
            requested_by_user: user,
            source_chat_message: source_chat_message,
            assistant_chat_message: assistant_chat_message,
            draft_type: "budget_edit",
            status: "pending",
            year: year,
            title: title,
            summary: summary,
            rationale: rationale,
            source_prompt: source_prompt,
            metadata: metadata
          )

          items.each_with_index do |item, index|
            draft.mia_action_items.create!(
              position: index,
              action_type: item.action_type,
              target_record_type: item.target_record_type,
              target_record_id: item.target_record_id,
              label: item.label,
              description: item.description,
              payload: item.payload,
              before_snapshot: item.before_snapshot,
              after_snapshot: item.after_snapshot
            )
          end
          household.household_audit_events.create!(
            user: user,
            actor_type: "mia",
            event_type: "mia_action_draft.proposed",
            auditable_type: "MiaActionDraft",
            auditable_id: draft.id,
            occurred_at: Time.current,
            metadata: {
              draft_id: draft.id,
              title: draft.title,
              item_count: draft.mia_action_items.size,
              source_prompt: source_prompt
            }
          )

          draft
        end
      end
    end

    def initialize(household, message = nil, user:, annual_budget_manager:, selected_month: Date.current.month, raw_input: nil, command: nil)
      @household = household
      @message = message.to_s.squish
      @user = user
      @annual_budget_manager = annual_budget_manager
      @selected_month = selected_month.to_i.clamp(1, 12)
      @raw_input = raw_input.presence || @message
      @command = command&.deep_symbolize_keys
    end

    def call
      return nil unless command.present? || action_text.match?(ACTION_TERMS)

      annual_budget_manager.ensure_plan!
      @annual_plan = annual_budget_manager.plan_data.deep_symbolize_keys
      return structured_command_result if command.present?
      return nil unless budget_edit_context?
      return existing_pending_action_result if duplicate_pending_action_confirmation?

      move_allocation_proposal ||
        rename_category_proposal ||
        reclassify_category_proposal ||
        archive_or_restore_category_proposal ||
        create_category_proposal ||
        allocation_amount_proposal
    end

    private

    attr_reader :household, :message, :user, :annual_budget_manager, :selected_month, :raw_input, :annual_plan, :command

    def action_text
      @action_text ||= begin
        if confirmation_follow_up? && prior_user_context.present?
          prior_user_context
        else
          current_follow_up_text.presence || message
        end
      end
    end

    def current_follow_up_text
      match = message.match(/\bCurrent follow-up:\s*(.+)\z/i)
      match&.[](1)&.squish
    end

    def prior_user_context
      match = message.match(/\bPrior user context:\s*(.+?)(?=\s+Prior Mia summary:|\s+Prior amount discussed:|\s+Prior next move:|\s+Current follow-up:|\z)/i)
      match&.[](1)&.squish
    end

    def prior_mia_summary
      match = message.match(/\bPrior Mia summary:\s*(.+?)(?=\s+Prior amount discussed:|\s+Prior next move:|\s+Current follow-up:|\z)/i)
      match&.[](1)&.squish
    end

    def confirmation_follow_up?
      current_follow_up_text.to_s.match?(/\A(?:yes|yeah|yep|yup|please|ok|okay|sure|for sure|go ahead)(?:[\s,!.]+(?:please|do that|do it|draft that|make that change|go ahead|yes|yeah|ok|okay|sure))*[\s,!.]*\z|\A(?:do that|do it|draft that|make that change|please do that|please do it)[\s,!.]*\z/i)
    end

    def budget_edit_context?
      return true if action_text.match?(BUDGET_CONTEXT_TERMS)
      return true if action_text.match?(/\b(move|transfer|shift)\b/i) && action_text.match?(MONEY_PATTERN) && action_text.match?(/\bfrom\b/i) && action_text.match?(/\bto\b/i)
      return true if action_text.match?(MONEY_PATTERN) && category_mentioned?
      return true if action_text.match?(MONEY_PATTERN) && contextual_active_category.present?

      false
    end

    def category_mentioned?
      active_rows.any? { |row| normalized_label(action_text).include?(normalized_label(row.fetch(:name))) }
    end

    def move_allocation_proposal
      match = action_text.match(/\b(?:move|transfer|shift)\s+(?<amount>#{MONEY_PATTERN})\s+(?:per\s+month\s+)?from\s+(?<from>.+?)\s+to\s+(?<to>.+?)\s*\z/i)
      return unless match

      amount_cents = amount_cents_from(match[:amount])
      return validation_result("I can draft budget moves only with a dollar amount above $0.") unless amount_cents.positive?

      from_category = find_active_category(resolved_category_phrase(match[:from]))
      to_category = find_active_category(resolved_category_phrase(match[:to]))
      missing = []
      missing << clean_category_phrase(match[:from]) unless from_category
      missing << clean_category_phrase(match[:to]) unless to_category
      return missing_category_result(missing) if missing.any?
      return validation_result("Choose two different categories before I draft a budget move.") if from_category.id == to_category.id

      month_numbers = month_numbers_for_message
      return month_numbers if month_numbers.is_a?(Result)

      from_changes = allocation_changes_for(from_category, month_numbers: month_numbers, mode: :decrease_by, amount_cents: amount_cents)
      return from_changes if from_changes.is_a?(Result)

      to_changes = allocation_changes_for(to_category, month_numbers: month_numbers, mode: :increase_by, amount_cents: amount_cents)
      return to_changes if to_changes.is_a?(Result)

      from_item = allocation_item(from_category, from_changes, "Reduce #{from_category.name} by #{money(amount_cents)}")
      to_item = allocation_item(to_category, to_changes, "Increase #{to_category.name} by #{money(amount_cents)}")
      scope = scope_label(month_numbers)
      summary = "I drafted a budget move of #{money(amount_cents)} per month from #{from_category.name} to #{to_category.name} for #{scope}."
      proposal_result(
        title: "Move planned dollars between categories",
        summary: summary,
        rationale: "This changes planned budget allocations only. Actual spending stays unchanged.",
        items: [ from_item, to_item ],
        metadata: { source: "mia_chat", parser: "move_allocation", month_numbers: month_numbers }
      )
    end

    def rename_category_proposal
      match = action_text.match(/\brename\s+(?:the\s+)?(?<from>.+?)\s+(?:category\s+)?(?:to|as)\s+(?<to>.+?)\s*\z/i)
      return unless match

      category = find_active_category(resolved_category_phrase(match[:from]))
      return missing_category_result([ clean_category_phrase(match[:from]) ]) unless category

      new_name = clean_new_category_name(match[:to])
      return validation_result("Tell me the new category name before I draft the rename.") if new_name.blank?
      return validation_result("#{category.name} already has that name.") if normalized_label(category.name) == normalized_label(new_name)
      return validation_result("A category named #{new_name} already exists. Rename or archive the existing category first.") if household.budget_categories.where("LOWER(name) = ?", new_name.downcase).where.not(id: category.id).exists?

      item = Item.new(
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
        metadata: { source: "mia_chat", parser: "rename_category" }
      )
    end

    def reclassify_category_proposal
      stack_key = stack_key_from_text(action_text)
      return unless stack_key
      return if action_text.match?(MONEY_PATTERN)

      match = action_text.match(/\b(?:reclassify|recategorize|change|move)\s+(?:the\s+)?(?<category>.+?)\s+(?:category\s+)?(?:to|as|into|under)\s+/i)
      return unless match

      category = find_active_category(resolved_category_phrase(match[:category]))
      return missing_category_result([ clean_category_phrase(match[:category]) ]) unless category
      return validation_result("#{category.name} is already in #{stack_label(stack_key)}.") if category.stack_key == stack_key

      item = Item.new(
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
        metadata: { source: "mia_chat", parser: "reclassify_category" }
      )
    end

    def archive_or_restore_category_proposal
      archive_match = action_text.match(/\b(?:archive|delete|remove)\s+(?:the\s+)?(?<category>.+?)(?:\s+category)?\s*\z/i)
      restore_match = action_text.match(/\brestore\s+(?:the\s+)?(?<category>.+?)(?:\s+category)?\s*\z/i)
      return unless archive_match || restore_match
      return unless action_text.match?(BUDGET_CONTEXT_TERMS) || contextual_active_category.present?

      if restore_match
        category = find_archived_category(restore_match[:category])
        return missing_category_result([ clean_category_phrase(restore_match[:category]) ], active: false) unless category

        item = Item.new(
          action_type: "restore_category",
          label: "Restore #{category.name}",
          description: "The category returns to the active annual budget view.",
          target_record_type: "BudgetCategory",
          target_record_id: category.id,
          payload: { category_id: category.id, year: annual_budget_manager.year },
          before_snapshot: category_snapshot(category),
          after_snapshot: category_snapshot(category).merge(active: true)
        )
        return proposal_result(
          title: "Restore budget category",
          summary: "I drafted restoring #{category.name} to the active budget.",
          rationale: "Restoring brings the category back for planning; it does not create actual spending.",
          items: [ item ],
          metadata: { source: "mia_chat", parser: "restore_category" }
        )
      end

      category = find_active_category(resolved_category_phrase(archive_match[:category]))
      return missing_category_result([ clean_category_phrase(archive_match[:category]) ]) unless category
      if category.transaction_drafts.pending.exists?
        return validation_result("#{category.name} has pending transaction drafts. Confirm, correct, or ignore those before archiving it.")
      end

      item = Item.new(
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
        metadata: { source: "mia_chat", parser: "archive_category" }
      )
    end

    def create_category_proposal
      return unless action_text.match?(/\b(add|create)\b/i)
      return unless action_text.match?(/\b(category|line item|budget row|budget category)\b/i)

      match = action_text.match(/\b(?:add|create)\s+(?:a\s+|an\s+)?(?:new\s+)?(?<body>.+?)\s*\z/i)
      return unless match

      body = match[:body]
      amount_match = body.match(/(?:at|for|with|to)\s+(?<amount>#{MONEY_PATTERN})(?:\s*(?:per month|monthly|\/month))?/i)
      amount_cents = amount_match ? amount_cents_from(amount_match[:amount]) : 0
      stack_key = stack_key_from_text(body) || "discretionary"
      name = clean_new_category_name(body.sub(amount_match.to_s, ""))
      name = name.gsub(/\b(?:for|in)\s+(?:#{MonthTerms.pattern})(?:\s+\d{4})?\b/i, " ").squish
      name = name.gsub(/\b(?:budget|category|line item|row|for|called|named|new|#{stack_alias_pattern})\b/i, " ").squish
      return validation_result("Tell me the category name before I draft a new budget row.") if name.blank?
      if (existing_category = household.budget_categories.find_by("LOWER(name) = ?", name.downcase))
        return existing_category_name_result(existing_category)
      end

      month_numbers = month_numbers_for_message
      return month_numbers if month_numbers.is_a?(Result)

      scope = scope_label(month_numbers)
      item = Item.new(
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
        metadata: { source: "mia_chat", parser: "create_category", month_numbers: month_numbers }
      )
    end

    def allocation_amount_proposal
      parsed = allocation_amount_request
      return unless parsed

      category_phrase = resolved_category_phrase(parsed.fetch(:category_phrase))
      category = find_active_category(category_phrase)
      return missing_category_result([ clean_category_phrase(parsed.fetch(:category_phrase)) ]) unless category

      amount_cents = parsed.fetch(:amount_cents)
      return validation_result("I can draft budget allocation edits only with a dollar amount of $0 or more.") if amount_cents.negative?

      month_numbers = month_numbers_for_message
      return month_numbers if month_numbers.is_a?(Result)

      changes = allocation_changes_for(category, month_numbers: month_numbers, mode: parsed.fetch(:mode), amount_cents: amount_cents)
      return changes if changes.is_a?(Result)
      return no_allocation_change_result(category, changes, mode: parsed.fetch(:mode), amount_cents: amount_cents, month_numbers: month_numbers) if no_allocation_change?(changes)

      item = allocation_item(category, changes, allocation_label(category, parsed.fetch(:mode), amount_cents))
      scope = scope_label(month_numbers)
      summary = allocation_summary(category, parsed.fetch(:mode), amount_cents, scope)
      proposal_result(
        title: "Edit planned budget dollars",
        summary: summary,
        rationale: "This changes planned budget allocations only. Actual spending does not change.",
        items: [ item ],
        metadata: { source: "mia_chat", parser: "allocation_amount", month_numbers: month_numbers, mode: parsed.fetch(:mode) }
      )
    end

    def existing_category_name_result(category)
      if category.active?
        validation_result("#{category.name} already exists. I can draft edits to the existing category instead.")
      else
        validation_result("#{category.name} is archived. Restore it before editing it, or choose a different name for the new category.")
      end
    end

    def duplicate_pending_action_confirmation?
      confirmation_follow_up? && prior_mia_summary.to_s.match?(/\b(?:drafted|review card)\b/i) && annual_plan.fetch(:pending_mia_action_drafts).any?
    end

    def existing_pending_action_result
      validation_result("I already prepared that budget review card. Use Apply to make the change, or Cancel if you do not want it. Nothing else changed yet.")
    end

    def allocation_amount_request
      if (match = action_text.match(/\b(?:set|change|update|adjust)\s+(?:my|our|the)?\s*(?<category>.+?)\s+(?:budget|allocation|planned(?:\s+amount)?|plan)?\s*(?:to|at|=)\s*(?<amount>#{MONEY_PATTERN})/i))
        return { category_phrase: match[:category], amount_cents: amount_cents_from(match[:amount]), mode: :set }
      end

      if (match = action_text.match(/\bmake\s+(?:my|our|the)?\s*(?<category>.+?)\s+(?<amount>#{MONEY_PATTERN})(?:\s*(?:per month|monthly|\/month))?/i))
        return { category_phrase: match[:category], amount_cents: amount_cents_from(match[:amount]), mode: :set }
      end

      if (match = action_text.match(/\b(?:increase|raise|bump\s+up)\s+(?:my|our|the)?\s*(?<category>.+?)\s+(?:(?<modifier>by|to|at)\s+)?(?<amount>#{MONEY_PATTERN})/i))
        mode = match[:modifier].to_s.downcase.in?(%w[to at]) ? :set : :increase_by
        return { category_phrase: match[:category], amount_cents: amount_cents_from(match[:amount]), mode: mode }
      end

      if (match = action_text.match(/\b(?:decrease|lower|reduce|cut)\s+(?:my|our|the)?\s*(?<category>.+?)\s+(?:(?<modifier>by|to|at)\s+)?(?<amount>#{MONEY_PATTERN})/i))
        mode = match[:modifier].to_s.downcase.in?(%w[to at]) ? :set : :decrease_by
        return { category_phrase: match[:category], amount_cents: amount_cents_from(match[:amount]), mode: mode }
      end

      nil
    end

    def proposal_result(title:, summary:, rationale:, items:, metadata: {})
      proposal = Proposal.new(
        household: household,
        user: user,
        year: annual_budget_manager.year,
        title: title,
        summary: summary,
        rationale: rationale,
        source_prompt: raw_input,
        items: items,
        metadata: metadata
      )
      Result.new(
        proposal: proposal,
        annual_plan: annual_plan,
        response: "#{summary} Review the draft card before applying it. Nothing changed in the official budget yet."
      )
    end

    def validation_result(response)
      Result.new(proposal: nil, response: response, annual_plan: annual_plan)
    end

    def missing_category_result(names, active: true)
      visible_names = names.map(&:presence).compact.presence || [ "that category" ]
      scope = active ? "active budget" : "archived budget"
      validation_result("I can draft that once I can match #{visible_names.to_sentence} to an #{scope} category. I did not change the budget.")
    end

    def allocation_changes_for(category, month_numbers:, mode:, amount_cents:)
      row = row_for_category(category)
      return missing_category_result([ category.name ]) unless row

      changes = month_numbers.map do |month_number|
        cell = row.fetch(:months).fetch(month_number - 1)
        return validation_result("#{category.name} is missing a #{month_label(month_number)} allocation. Open the annual budget once, then ask Mia to draft this again.") if cell.fetch(:allocation_id).blank?

        before_cents = cents_from_dollars(cell.fetch(:planned))
        after_cents = case mode
        when :set
          amount_cents
        when :increase_by
          before_cents + amount_cents
        when :decrease_by
          before_cents - amount_cents
        else
          before_cents
        end
        if after_cents.negative?
          return validation_result("That would make #{category.name} negative in #{month_label(month_number)}. I did not draft the change.")
        end

        {
          month: month_number,
          month_label: month_label(month_number),
          budget_period_id: cell.fetch(:period_id),
          allocation_id: cell.fetch(:allocation_id),
          before_cents: before_cents,
          after_cents: after_cents
        }
      end

      changes
    end

    def no_allocation_change?(changes)
      changes.all? { |change| change.fetch(:before_cents) == change.fetch(:after_cents) }
    end

    def no_allocation_change_result(category, changes, mode:, amount_cents:, month_numbers:)
      scope = scope_label(month_numbers)
      if mode == :set
        return validation_result("#{category.name} is already #{money(amount_cents)} for #{scope}. I did not create a draft because nothing would change.")
      end

      current_amounts = changes.map { |change| money(change.fetch(:before_cents)) }.uniq.to_sentence
      validation_result("That would leave #{category.name} unchanged for #{scope} at #{current_amounts}. I did not create a draft because nothing would change.")
    end

    def allocation_item(category, changes, label)
      before_values = changes.index_by { |change| change.fetch(:month) }.transform_values { |change| change.fetch(:before_cents) }
      after_values = changes.index_by { |change| change.fetch(:month) }.transform_values { |change| change.fetch(:after_cents) }
      Item.new(
        action_type: "update_allocation",
        label: label,
        description: allocation_description(category, changes),
        target_record_type: "BudgetCategory",
        target_record_id: category.id,
        payload: { category_id: category.id, category_name: category.name, year: annual_budget_manager.year, changes: changes },
        before_snapshot: { category_id: category.id, category_name: category.name, monthly_amounts_cents: before_values },
        after_snapshot: { category_id: category.id, category_name: category.name, monthly_amounts_cents: after_values }
      )
    end

    def allocation_description(category, changes)
      if changes.length == 12 && changes.map { |change| change.fetch(:before_cents) }.uniq.one? && changes.map { |change| change.fetch(:after_cents) }.uniq.one?
        return "Every month in #{annual_budget_manager.year}: #{category.name} changes from #{money(changes.first.fetch(:before_cents))} to #{money(changes.first.fetch(:after_cents))}."
      end

      changes.map do |change|
        "#{change.fetch(:month_label)}: #{money(change.fetch(:before_cents))} to #{money(change.fetch(:after_cents))}"
      end.to_sentence
    end

    def allocation_label(category, mode, amount_cents)
      case mode
      when :increase_by
        "Increase #{category.name} by #{money(amount_cents)}"
      when :decrease_by
        "Reduce #{category.name} by #{money(amount_cents)}"
      else
        "Set #{category.name} to #{money(amount_cents)}"
      end
    end

    def allocation_summary(category, mode, amount_cents, scope)
      case mode
      when :increase_by
        "I drafted increasing #{category.name} by #{money(amount_cents)} for #{scope}."
      when :decrease_by
        "I drafted reducing #{category.name} by #{money(amount_cents)} for #{scope}."
      else
        "I drafted setting #{category.name} to #{money(amount_cents)} for #{scope}."
      end
    end

    def month_numbers_for_message
      return (1..12).to_a if action_text.match?(ALL_YEAR_TERMS)

      lowered = action_text.downcase
      relative_date = if lowered.match?(/\b(this|current) month\b/)
        Date.current
      elsif lowered.match?(/\bnext month\b/)
        Date.current.next_month
      elsif lowered.match?(/\blast month\b/)
        Date.current.prev_month
      end
      if relative_date
        return [ relative_date.month ] if relative_date.year == annual_budget_manager.year

        direction = if lowered.match?(/\bnext month\b/)
          "Next month"
        elsif lowered.match?(/\blast month\b/)
          "Last month"
        else
          "This month"
        end
        return validation_result("#{direction} falls outside the #{annual_budget_manager.year} budget. Open #{relative_date.year} or name a month in #{annual_budget_manager.year}; nothing changed.")
      end

      explicit_month = MonthTerms.detect_number(action_text)
      return [ explicit_month ] if explicit_month

      (1..12).to_a
    end

    def scope_label(month_numbers)
      return "every month in #{annual_budget_manager.year}" if month_numbers.length == 12

      month_numbers.map { |month| "#{month_label(month)} #{annual_budget_manager.year}" }.to_sentence
    end

    def month_label(month_number)
      AnnualBudgetManager::MONTH_NAMES.fetch(month_number.to_i - 1)
    end

    def active_rows
      annual_plan.fetch(:rows).select { |row| row.fetch(:active, true) }
    end

    def row_for_category(category)
      active_rows.find { |row| row.fetch(:id).to_i == category.id }
    end

    def find_active_category(phrase)
      find_category_in_scope(phrase, household.budget_categories.active.ordered.to_a)
    end

    def resolved_category_phrase(phrase)
      cleaned = clean_category_phrase(phrase)
      contextual = contextual_active_category&.name
      return contextual if contextual.present? && ambiguous_category_phrase?(cleaned)

      cleaned
    end

    def ambiguous_category_phrase?(phrase)
      normalized = normalized_label(phrase)
      return true if normalized.blank?

      normalized.match?(/\A(?:that|this|it|one|same|current|previous|largest|biggest|highest|top)(?:\s+(?:one|category|line|row|amount|budget|plan|down|up))*\z/)
    end

    def contextual_active_category
      @contextual_active_category ||= begin
        context_subjects.filter_map { |subject| find_active_category(subject) }.first
      end
    end

    def context_subjects
      message.scan(/\bSubject:\s*(.+?)(?=\.\s+(?:Prior|Current|Topic:)|\.\z|\z)/i).flatten.map(&:squish)
    end

    def find_archived_category(phrase)
      find_category_in_scope(phrase, household.budget_categories.archived.ordered.to_a)
    end

    def find_category_in_scope(phrase, categories)
      cleaned = normalized_label(clean_category_phrase(phrase))
      return if cleaned.blank?

      exact = categories.find { |category| label_matches?(normalized_label(category.name), cleaned) }
      return exact if exact

      candidates = categories.select do |category|
        category_label = normalized_label(category.name)
        cleaned.include?(category_label) || category_label.include?(cleaned)
      end
      return candidates.first if candidates.one?

      longest_candidates = candidates.group_by { |category| normalized_label(category.name).length }.max_by { |length, _group| length }&.last
      return longest_candidates.first if longest_candidates&.one?

      nil
    end

    def label_matches?(left, right)
      left == right || left.singularize == right.singularize
    end

    def clean_category_phrase(value)
      value.to_s
        .sub(/\s+(?:for|in)\s+(?:#{MonthTerms.pattern}|this month|current month|next month|last month|all year|every month).*\z/i, "")
        .gsub(MONEY_PATTERN, " ")
        .gsub(/\b(?:my|our|the|a|an|budget|category|categories|allocation|planned|amount|plan|monthly|per month|\/month|from|to|as|into|under)\b/i, " ")
        .squish
    end

    def clean_new_category_name(value)
      value.to_s
        .gsub(/\b(?:my|our|the|a|an|to|as|at|with|per month|monthly|\/month)\b/i, " ")
        .squish
        .truncate(80, omission: "…")
    end

    def normalized_label(value)
      value.to_s.downcase.gsub(/[^a-z0-9\s]/, " ").squish
    end

    def amount_cents_from(value)
      Money.cents!(value.to_s.delete("$, "), message: "Amount must be a number")
    rescue ArgumentError
      -1
    end

    def cents_from_dollars(value)
      (value.to_f * 100).round
    end

    def category_snapshot(category)
      {
        id: category.id,
        name: category.name,
        stack_key: category.stack_key,
        stack_label: category.stack_label,
        active: category.active
      }
    end

    def stack_key_from_text(text)
      normalized = normalized_label(text)
      return "non_discretionary" if normalized.match?(/\b(non discretionary|fixed|essential|essentials|bills|needs)\b/)
      return "sinking_expected" if normalized.match?(/\b(expected sinking|sinking expected|planned irregular|annual bill|annual bills)\b/)
      return "sinking_unexpected" if normalized.match?(/\b(unexpected sinking|sinking unexpected|surprise|unplanned)\b/)
      return "discretionary" if normalized.match?(/\b(discretionary|flexible|wants|fun)\b/)

      nil
    end

    def stack_alias_pattern
      "non[-\\s]?discretionary|fixed|essential|essentials|bills|needs|expected sinking|sinking expected|sinking fund expected|planned irregular|annual bills?|unexpected sinking|sinking unexpected|sinking fund unexpected|surprise|unplanned|discretionary|flexible|wants|fun"
    end

    def stack_label(stack_key)
      STACK_LABELS.fetch(stack_key, stack_key.to_s.humanize)
    end

    def money(cents)
      ActiveSupport::NumberHelper.number_to_currency(Money.dollars(cents), precision: cents.to_i % 100 == 0 ? 0 : 2)
    end
  end
end
