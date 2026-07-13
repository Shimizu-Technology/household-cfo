# frozen_string_literal: true

module HouseholdFinance
  class TransactionDraftBudgetImpact
    def initialize(annual_plan:, draft:)
      @annual_plan = annual_plan || {}
      @draft = draft
    end

    def call
      candidate_allocations.map do |category_id, allocation|
        row = rows.find { |candidate| value(candidate, :id).to_i == category_id.to_i } if category_id
        cell = Array(value(row, :months))[occurred_on.month - 1] if row
        unless category_id && row && cell
          next {
            category_id: category_id,
            category_name: allocation.fetch(:category_name).presence || "Needs category",
            draft_amount_cents: allocation.fetch(:amount_cents),
            status: "needs_category"
          }
        end

        planned_cents = Money.cents(value(cell, :planned))
        actual_cents = Money.cents(value(cell, :actual))
        other_pending_cents = other_pending_by_category.fetch(category_id.to_i, 0)
        projected_cents = actual_cents + other_pending_cents + allocation.fetch(:amount_cents)
        {
          category_id: category_id.to_i,
          category_name: value(row, :name),
          draft_amount_cents: allocation.fetch(:amount_cents),
          planned_cents: planned_cents,
          actual_cents: actual_cents,
          other_pending_cents: other_pending_cents,
          projected_if_approved_cents: projected_cents,
          remaining_if_approved_cents: planned_cents - projected_cents,
          status: planned_cents - projected_cents < 0 ? "over" : "within_plan"
        }
      end
    end

    private

    attr_reader :annual_plan, :draft

    def rows
      @rows ||= Array(value(annual_plan, :rows))
    end

    def occurred_on
      @occurred_on ||= if draft.respond_to?(:occurred_on)
        draft.occurred_on.to_date
      else
        Date.iso8601(value(draft, :occurred_on).to_s)
      end
    end

    def candidate_allocations
      @candidate_allocations ||= allocations_for(draft)
    end

    def other_pending_by_category
      @other_pending_by_category ||= Array(value(annual_plan, :pending_transaction_drafts)).each_with_object(Hash.new(0)) do |pending_draft, totals|
        next if value(pending_draft, :id).to_i == draft_id
        next unless Date.iso8601(value(pending_draft, :occurred_on).to_s).month == occurred_on.month

        allocations_for(pending_draft).each do |category_id, allocation|
          next unless category_id

          totals[category_id.to_i] += allocation.fetch(:amount_cents)
        end
      rescue Date::Error
        next
      end
    end

    def allocations_for(source)
      splits = if source.respond_to?(:transaction_draft_splits)
        source.transaction_draft_splits.ordered.includes(:budget_category).to_a
      else
        Array(value(source, :splits))
      end

      allocations = {}
      splits.each do |split|
        amount_cents = cents_value(split)
        next unless amount_cents.positive?

        category_id = value(split, :budget_category_id)&.to_i
        category_name = if split.respond_to?(:budget_category)
          split.budget_category&.name || value(split, :category_name)
        else
          value(split, :category_name)
        end
        current = allocations[category_id] || { amount_cents: 0, category_name: category_name }
        current[:amount_cents] += amount_cents
        current[:category_name] ||= category_name
        allocations[category_id] = current
      end
      return allocations if allocations.any?

      category_id = value(source, :budget_category_id) || value(source, :category_id)
      category_name = if source.respond_to?(:budget_category)
        source.budget_category&.name || value(source, :category_name)
      else
        value(source, :category_name)
      end
      { category_id&.to_i => { amount_cents: cents_value(source), category_name: category_name } }
    end

    def cents_value(source)
      cents = value(source, :amount_cents)
      cents = source.total_amount_cents if cents.nil? && source.respond_to?(:total_amount_cents)
      return cents.to_i unless cents.nil?

      Money.cents(value(source, :amount))
    end

    def draft_id
      value(draft, :id).to_i
    end

    def value(source, key)
      return if source.nil?
      return source.public_send(key) if source.respond_to?(key)

      source[key] || source[key.to_s]
    end
  end
end
