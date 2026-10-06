# frozen_string_literal: true

module HouseholdFinance
  class MiaReadOnlyPlanAnswerer
    Result = Struct.new(:answer, :presentation, :annual_plan, :items, keyword_init: true)
    MAX_SECTION_BODY_BYTES = 1_800
    TOTAL_SECTION_BODY_BYTES = 3_500
    MAX_SCENARIO_LABEL_BYTES = 120

    TITLES = {
      "coaching" => "Household CFO guidance",
      "budget_question" => "Budget answer",
      "spending_report" => "Spending report",
      "transaction_lookup" => "Transaction history",
      "pending_drafts" => "Pending reviews"
    }.freeze

    def initialize(household, plan:, annual_budget_manager:, annual_plan:, reference_month:, conversation_messages: [])
      @household = household
      @plan = plan.to_h.deep_symbolize_keys
      @annual_budget_manager = annual_budget_manager
      @reference_month = reference_month.to_i.clamp(1, 12)
      @conversation_messages = Array(conversation_messages)
      @prepared_annual_plan = annual_plan.deep_symbolize_keys
    end

    def call
      items = Array(plan[:items])
      raise ArgumentError, "Read-only plan must contain one to six items" unless items.length.between?(1, 6)

      scenario_values = []
      sections = items.each_with_index.map do |item, index|
        section, scenario_value = answer_item(item.deep_symbolize_keys, index)
        scenario_values << compact_scenario_value(scenario_value) if scenario_value
        section
      rescue StandardError => e
        Rails.logger.warn("Mia read-only plan part failed kind=#{item.to_h[:kind]}: #{e.class}: #{e.message}")
        {
          id: "part-#{index + 1}",
          title: title_for(item.to_h.deep_symbolize_keys),
          body: "I could not answer this part safely from approved household data. No financial records or reviews changed."
        }
      end
      sections = compact_sections(sections)

      basis = presentation_basis(items, scenario_values)
      lead = lead_for(basis, sections.length)
      presentation = {
        version: 1,
        kind: "read_only_answer",
        basis: basis,
        lead: lead,
        sections: sections
      }
      presentation[:scenario] = { values: scenario_values } if scenario_values.any?

      Result.new(
        answer: canonical_text(lead, sections),
        presentation: presentation,
        annual_plan: prepared_annual_plan,
        items: items
      )
    end

    private

    attr_reader :household, :plan, :annual_budget_manager, :reference_month, :conversation_messages, :prepared_annual_plan

    def answer_item(item, index)
      if item.fetch(:kind) == "scenario"
        scenario = MiaHypotheticalScenarioAnswerer.new(
          household,
          scenario_type: item.fetch(:scenario_type),
          amount: item.fetch(:amount),
          label: item.fetch(:scenario_label),
          effective_on: item[:effective_on],
          timing_unavailable: item[:timing_unavailable],
          annual_budget_manager: annual_budget_manager,
          reference_month: reference_month
        ).call
        return [ { id: "part-#{index + 1}", title: scenario.title, body: scenario.body }, scenario.scenario_value ]
      end

      question = item.fetch(:resolved_question)
      body = send("answer_#{item.fetch(:kind)}", question)
      body = "I could not answer this part safely from approved household data. No financial records or reviews changed." if body.blank?
      [ { id: "part-#{index + 1}", title: title_for(item), body: body }, nil ]
    end

    def answer_coaching(question)
      MiaCoachAnswerer.new(
        household,
        question,
        annual_budget_manager: annual_budget_manager,
        annual_plan: prepared_annual_plan,
        reference_month: reference_month,
        conversation_messages: conversation_messages,
        ensure_plan: false
      ).call
    end

    def answer_budget_question(question)
      unless prepared_annual_plan.fetch(:plan_available, true)
        return "No approved annual budget plan is available for #{annual_budget_manager.year}, so I cannot present confirmed setup amounts as an approved month-by-month plan. No budget records or reviews were created. Open the budget manually if you want to create that plan."
      end

      requested_year = BudgetQuestionAnswerer.relative_budget_year(question)
      if requested_year && requested_year != annual_budget_manager.year
        return "This read-only answer is limited to the approved #{annual_budget_manager.year} plan already open. Open #{requested_year} and ask again so I do not create or infer another year's plan. No records or reviews changed."
      end

      normalized = BudgetQuestionAnswerer.normalized(question)
      if normalized.match?(BudgetQuestionAnswerer::LARGEST_CATEGORY_PATTERN) || normalized.match?(BudgetQuestionAnswerer::SMALLEST_CATEGORY_PATTERN)
        return BudgetQuestionAnswerer.new(question, annual_plan: prepared_annual_plan, reference_month: reference_month).call
      end

      MiaCoachAnswerer.new(
        household,
        question,
        annual_budget_manager: annual_budget_manager,
        annual_plan: prepared_annual_plan,
        reference_month: reference_month,
        conversation_messages: conversation_messages,
        ensure_plan: false
      ).call.presence ||
        BudgetQuestionAnswerer.new(question, annual_plan: prepared_annual_plan, reference_month: reference_month).call
    end

    def answer_spending_report(question)
      range = SpendingReportQuery.new(question).range
      return unless range

      report = SpendingReport.new(
        household,
        start_on: range.fetch(:start_on),
        end_on: range.fetch(:end_on),
        ensure_plans: false
      ).as_json
      SpendingReportNarrator.new(report, prompt: question).call
    end

    def answer_transaction_lookup(question)
      TransactionLookupAnswerer.new(household, question).call
    end

    def answer_pending_drafts(question)
      PendingDraftAnswerer.new(household, question).call
    end

    def title_for(item)
      return MiaHypotheticalScenarioAnswerer::TITLES.fetch(item[:scenario_type], "Scenario") if item[:kind] == "scenario"

      TITLES.fetch(item[:kind], "Household CFO answer")
    end

    def presentation_basis(items, scenario_values)
      return "saved_household" if scenario_values.empty?
      return "scenario_only" if items.all? { |item| item.to_h.deep_symbolize_keys[:kind] == "scenario" }

      "saved_household_plus_scenario"
    end

    def lead_for(basis, count)
      case basis
      when "saved_household"
        "Here are all #{count} answers from your saved household data."
      when "scenario_only"
        "Here are all #{count} scenarios. These values are unapproved and were not saved."
      else
        "Here are all #{count} answers. Saved household facts and unapproved scenario values are labeled separately."
      end
    end

    def canonical_text(lead, sections)
      ([ lead ] + sections.map.with_index { |section, index| "#{index + 1}. #{section.fetch(:title)}\n#{section.fetch(:body)}" }).join("\n\n")
    end

    def compact_sections(sections)
      per_section_bytes = [ TOTAL_SECTION_BODY_BYTES / sections.length, MAX_SECTION_BODY_BYTES ].min
      sections.map do |section|
        section.merge(body: truncate_bytes(section.fetch(:body), per_section_bytes))
      end
    end

    def compact_scenario_value(value)
      value.merge(label: truncate_bytes(value.fetch(:label), MAX_SCENARIO_LABEL_BYTES))
    end

    def truncate_bytes(value, maximum)
      text = value.to_s
      return text if text.bytesize <= maximum

      omission = "…"
      kept = +""
      text.each_char do |character|
        break if kept.bytesize + character.bytesize + omission.bytesize > maximum

        kept << character
      end
      "#{kept}#{omission}"
    end
  end
end
