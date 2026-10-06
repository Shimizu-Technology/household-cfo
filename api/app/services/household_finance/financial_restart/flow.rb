require "digest"

module HouseholdFinance
  module FinancialRestart
    class Flow
      Error = Class.new(ArgumentError)
      StaleReview = Class.new(Error)
      OwnerRequired = Class.new(Error)
      AdminRequired = Class.new(Error)
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

      def initialize(household, user:, cohort_membership: nil)
        @household, @user, @membership = household, user, cohort_membership
      end

      def status(review_id: nil)
        ChallengePrivacy::PrivateFinanceAccess.authorize!(household, user: user)
        actor = User.find_by(id: user.id)
        owner = household.household_memberships.exists?(user_id: user.id, role: "owner")
        available = actor&.admin? && !actor.revoked? && owner
        if review_id
          authorize!
          latest = household.financial_restart_reviews.where(requested_by_user: user, cohort_id: cohort_id).find(review_id)
        elsif available
          latest = household.financial_restart_reviews.where(requested_by_user: user, cohort_id: cohort_id).order(id: :desc).first
        end
        { available: !!available, admin_required: !actor&.admin?, owner_required: !owner, financial_generation: household.reload.financial_generation,
          household_id: household.id, household_name: household.name, latest_review: latest && serialize(latest) }
      end

      def preview
        household.with_lock do
          FinancialGenerationGuard.request!(household)
          authorize!
          data = inventory
          review = household.financial_restart_reviews.create!(requested_by_user: user, cohort_id: cohort_id,
            financial_generation: household.financial_generation, inventory: data, inventory_fingerprint: fingerprint(data),
            expires_at: 15.minutes.from_now)
          status.merge(review: serialize(review))
        end
      end

      def apply(review_id:, confirmation:, shared_household_acknowledged: false)
        household.with_lock do
          authorize!
          review = household.financial_restart_reviews.where(requested_by_user: user, cohort_id: cohort_id).find(review_id)
          return status.merge(review: serialize(review), setup_required: true) if review.status == "applied"
          raise Error, "This review was canceled. Open a fresh review. Nothing changed." if review.status == "canceled"
          raise Error, "Confirm the reviewed financial restart. Nothing changed." unless confirmation == "START OVER"
          if shared_member_count.positive? && !ActiveModel::Type::Boolean.new.cast(shared_household_acknowledged)
            raise Error, "Confirm that this starts a new financial picture for everyone in this household. Nothing changed."
          end
          data = inventory
          if review.expires_at <= Time.current || review.financial_generation != household.financial_generation || review.inventory_fingerprint != fingerprint(data)
            raise StaleReview, "Your financial picture changed or this review expired. Open a fresh review before starting over. Nothing changed."
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
          status.merge(review: serialize(review), setup_required: true)
        end
      end

      def cancel(review_id:)
        household.with_lock do
          authorize!
          review = household.financial_restart_reviews.where(requested_by_user: user, cohort_id: cohort_id).find(review_id)
          review.update!(status: "canceled") if review.status == "pending"
          status.merge(review: serialize(review))
        end
      end

      private

      attr_reader :household, :user, :membership
      def cohort_id = membership&.cohort_id
      def shared_member_count = household.household_memberships.where.not(user_id: user.id).count

      def authorize!
        actor = User.lock.find_by(id: user.id)
        raise OwnerRequired, "This account no longer has permission to restart financial records. Nothing changed." unless actor && !actor.revoked?
        raise AdminRequired, "Starting over is an administrator testing tool. Update individual records through Mia or My Money instead. Nothing changed." unless actor.admin?
        raise OwnerRequired, "Only an administrator who owns this household can reset its test financial picture. Nothing changed." unless household.household_memberships.exists?(user_id: user.id, role: "owner")
        selected = ::Mia::EffectiveCohortResolver.new(user: user, role: "participant", requested_cohort_id: cohort_id).call if cohort_id
        if selected&.cohort&.savings_challenge_enabled
          SavingsChallenge::AccessPolicy.new(household: household, user: user, cohort: selected.cohort).call!
        elsif selected.nil? && ChallengePrivacy::PrivateFinanceAccess.pilot_household?(household)
          raise OwnerRequired, "Choose your current coaching program before reviewing a financial restart. Nothing changed."
        end
        ChallengePrivacy::PrivateFinanceAccess.authorize!(household, user: user)
      end

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
          version_fingerprint: fingerprint(rows.merge(setup: household.attributes.slice("confirmed_setup_fields", "primary_goal"), profile: household.household_profile.attributes, memberships: household.household_memberships.order(:id).pluck(:id, :role))),
          reset_fields: [ "Financial setup and confirmations", "Income (including historical and future schedules)", "Spending categories, plans and actuals", "Debts, accounts and goals", "Active Mia conversation (earlier conversations move to private history)" ],
          preserved: PRESERVED, paused: PAUSED, clears_chat: true, clears_memories: false }
      end

      def fingerprint(value) = Digest::SHA256.hexdigest(JSON.generate(value))

      def serialize(review)
        review.inventory.symbolize_keys.except(:version_fingerprint).merge(id: review.id, status: review.status,
          financial_generation: review.financial_generation, expires_at: review.expires_at.iso8601,
          applied_at: review.applied_at&.iso8601, result_generation: review.result_generation)
      end
    end
  end
end
