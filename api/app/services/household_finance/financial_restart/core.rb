require "digest"

module HouseholdFinance
  module FinancialRestart
    # Internal snapshot/rollover engine. Public facades must authorize and hold
    # the household lock before creating, applying or canceling a review.
    class Core
      ROOTS = %w[income_sources expense_items debts accounts goals budget_years budget_categories household_transactions transaction_drafts mia_action_drafts merchant_category_rules].freeze
      ROW_DIGESTS = {
        "income_sources" => Arel.sql("encode(sha256(convert_to(row_to_json(income_sources.*)::text, 'UTF8')), 'hex')"),
        "expense_items" => Arel.sql("encode(sha256(convert_to(row_to_json(expense_items.*)::text, 'UTF8')), 'hex')"),
        "debts" => Arel.sql("encode(sha256(convert_to(row_to_json(debts.*)::text, 'UTF8')), 'hex')"),
        "accounts" => Arel.sql("encode(sha256(convert_to(row_to_json(accounts.*)::text, 'UTF8')), 'hex')"),
        "goals" => Arel.sql("encode(sha256(convert_to(row_to_json(goals.*)::text, 'UTF8')), 'hex')"),
        "budget_years" => Arel.sql("encode(sha256(convert_to(row_to_json(budget_years.*)::text, 'UTF8')), 'hex')"),
        "budget_categories" => Arel.sql("encode(sha256(convert_to(row_to_json(budget_categories.*)::text, 'UTF8')), 'hex')"),
        "household_transactions" => Arel.sql("encode(sha256(convert_to(row_to_json(household_transactions.*)::text, 'UTF8')), 'hex')"),
        "transaction_drafts" => Arel.sql("encode(sha256(convert_to(row_to_json(transaction_drafts.*)::text, 'UTF8')), 'hex')"),
        "mia_action_drafts" => Arel.sql("encode(sha256(convert_to(row_to_json(mia_action_drafts.*)::text, 'UTF8')), 'hex')"),
        "merchant_category_rules" => Arel.sql("encode(sha256(convert_to(row_to_json(merchant_category_rules.*)::text, 'UTF8')), 'hex')"),
        "income_schedule_entries" => Arel.sql("encode(sha256(convert_to(row_to_json(income_schedule_entries.*)::text, 'UTF8')), 'hex')"),
        "financial_document_imports" => Arel.sql("encode(sha256(convert_to(row_to_json(financial_document_imports.*)::text, 'UTF8')), 'hex')"),
        "plaid_items" => Arel.sql("encode(sha256(convert_to(row_to_json(plaid_items.*)::text, 'UTF8')), 'hex')"),
        "budget_allocations" => Arel.sql("encode(sha256(convert_to(row_to_json(budget_allocations.*)::text, 'UTF8')), 'hex')"),
        "transaction_splits" => Arel.sql("encode(sha256(convert_to(row_to_json(transaction_splits.*)::text, 'UTF8')), 'hex')"),
        "transaction_draft_splits" => Arel.sql("encode(sha256(convert_to(row_to_json(transaction_draft_splits.*)::text, 'UTF8')), 'hex')")
      }.freeze
      PRESERVED = [ "Login, household name and members", "BOG enrollment, savings, evidence and optional card reviews", "Original uploads and bank connections", "Audit and previous financial history", "Earlier conversations retained privately as read-only history", "Saved private memories (paused in Mia until reviewed)" ].freeze
      PAUSED = [ "Earlier document applications", "Earlier bank transaction staging and automatic confirmation", "Previous chat continuity and saved-memory context" ].freeze


      def initialize(household, user:)
        @household, @user = household, user
      end

      def create_review!(cohort_id:, purpose:, support_request: nil)
        data = inventory
        household.financial_restart_reviews.create!(requested_by_user: user, cohort_id: cohort_id, purpose: purpose,
          setup_support_request: support_request, financial_generation: household.financial_generation,
          inventory: data, inventory_fingerprint: fingerprint(data), expires_at: 15.minutes.from_now)
      end

      def apply_review!(review, confirmation:, shared_household_acknowledged:)
        return review if review.status == "applied"
        raise Flow::Error, "This review was canceled. Open a fresh review. Nothing changed." unless review.status == "pending"
        raise Flow::Error, "Confirm the reviewed financial restart. Nothing changed." unless confirmation == "START OVER"
        if shared_member_count.positive? && shared_household_acknowledged != true
          raise Flow::Error, "Confirm that this starts a new financial picture and conversation continuity for everyone in this household. Nothing changed."
        end
        data = inventory
        if review.expires_at <= Time.current || review.financial_generation != household.financial_generation || review.inventory_fingerprint != fingerprint(data)
          raise Flow::StaleReview, "Your financial picture changed or this review expired. Open a fresh review before starting over. Nothing changed."
        end
        generation = household.financial_generation + 1
        prior = household.attributes.slice("confirmed_setup_fields", "primary_goal", "stage").merge("profile" => household.household_profile.attributes.except("id", "household_id", "created_at", "updated_at"))
        household.update!(financial_generation: generation, confirmed_setup_fields: [], primary_goal: nil)
        profile = household.household_profile
        profile.update!(financial_generation: generation, debt_tracking_mode: "individual", debt_summary_balance_cents: 0,
          debt_summary_balance_known: false, debt_summary_minimum_payment_cents: 0, debt_summary_minimum_payment_known: false,
          primary_decision: nil, household_stage: nil, money_stress_level: nil, notes: nil)
        household.chat_sessions.update_all(financial_generation: generation, active_topic: {}, open_topics: [], rolling_summary: nil, last_compacted_message_id: nil, last_compacted_at: nil, updated_at: Time.current)
        MiaMessageRequest.where(chat_session_id: household.chat_sessions.select(:id), status: "processing").where.not(financial_generation: generation).update_all(
          status: "failed", response_status: 409, completed_at: Time.current,
          response_payload: { "code" => "financial_generation_stale", "error" => "Your financial picture restarted. Send a fresh message; earlier conversation context is retained as history." }, updated_at: Time.current)
        review.update!(status: "applied", applied_at: Time.current, result_generation: generation, previous_setup: prior)
        household.household_audit_events.create!(user: user, actor_type: "user", event_type: "financial_restart.applied",
          auditable_type: "FinancialRestartReview", auditable_id: review.id, occurred_at: Time.current, metadata: { previous_generation: review.financial_generation, financial_generation: generation, counts: data.fetch(:counts) })
        household.reload
        review
      end

      def cancel_review!(review)
        review.update!(status: "canceled") if review.status == "pending"
      end

      def serialize(review)
        review.inventory.symbolize_keys.except(:version_fingerprint).merge(id: review.id, status: review.status,
          financial_generation: review.financial_generation, expires_at: review.expires_at.iso8601,
          applied_at: review.applied_at&.iso8601, result_generation: review.result_generation)
      end

      private
      attr_reader :household, :user
      def shared_member_count = household.household_memberships.where.not(user_id: user.id).count

      def inventory
        rows = ROOTS.index_with do |association|
          household.public_send(association).order(:id).pluck(:id, ROW_DIGESTS.fetch(association))
        end
        rows[:income_schedule_entries] = IncomeScheduleEntry.where(income_source_id: rows.fetch("income_sources").map(&:first)).order(:id).pluck(:id, ROW_DIGESTS.fetch("income_schedule_entries"))
        rows[:document_imports] = household.financial_document_imports.current_picture.order(:id).pluck(:id, ROW_DIGESTS.fetch("financial_document_imports"))
        rows[:bank_connections] = household.plaid_items.current_picture.order(:id).pluck(:id, ROW_DIGESTS.fetch("plaid_items"))
        periods = BudgetPeriod.where(budget_year_id: rows.fetch("budget_years").map(&:first)).pluck(:id)
        rows[:budget_allocations] = BudgetAllocation.where(budget_period_id: periods).order(:id).pluck(:id, ROW_DIGESTS.fetch("budget_allocations"))
        rows[:transaction_splits] = TransactionSplit.where(household_transaction_id: rows.fetch("household_transactions").map(&:first)).order(:id).pluck(:id, ROW_DIGESTS.fetch("transaction_splits"))
        rows[:transaction_draft_splits] = TransactionDraftSplit.where(transaction_draft_id: rows.fetch("transaction_drafts").map(&:first)).order(:id).pluck(:id, ROW_DIGESTS.fetch("transaction_draft_splits"))
        { household_id: household.id, household_name: household.name, financial_generation: household.financial_generation,
          shared_member_count: shared_member_count, counts: rows.transform_values(&:length),
          version_fingerprint: fingerprint(rows.merge(setup: household.attributes.slice("confirmed_setup_fields", "primary_goal"), profile: household.household_profile.attributes, memberships: household.household_memberships.order(:id).pluck(:id, :user_id, :role), eligibility: SetupHelp::Eligibility.new(household).snapshot)),
          reset_fields: [ "Financial setup and confirmations", "Income (including historical and future schedules)", "Spending categories, plans and actuals", "Debts, accounts and goals", "Active Mia conversations for every household member (earlier conversations move to each person’s private history)" ],
          preserved: PRESERVED, paused: PAUSED, clears_chat: true, clears_memories: false }
      end

      def fingerprint(value) = Digest::SHA256.hexdigest(JSON.generate(value))
    end
  end
end
