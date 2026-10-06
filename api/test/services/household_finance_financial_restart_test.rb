require "test_helper"

class HouseholdFinanceFinancialRestartTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(clerk_id: "restart_#{SecureRandom.hex(6)}", email: "restart-#{SecureRandom.hex(6)}@example.com", role: "admin", invitation_status: "accepted")
    @household = Household.create!(created_by_user: @user, name: "Restart household", primary_goal: "Fake goal", confirmed_setup_fields: %w[monthly_income fixed_expenses flexible_expenses emergency_fund debt_balance])
    @household.household_memberships.create!(user: @user, role: "owner")
    @flow = HouseholdFinance::FinancialRestart::Flow.new(@household, user: @user)
  end

  test "reviewed restart isolates historical and future financial records and preserves their history" do
    source = @household.income_sources.create!(label: "Salary", source_type: "job", cadence: "monthly", amount_cents: 400_000)
    source.income_schedule_entries.create!(entry_type: "recurring_change", cadence: "monthly", effective_on: "2027-01-01", amount_cents: 500_000)
    @household.income_sources.create!(label: "Ended job", source_type: "job", cadence: "monthly", amount_cents: 100_000, active: false, ends_on: "2026-10-01")
    @household.expense_items.create!(label: "Rent", stack_key: "non_discretionary", cadence: "monthly", amount_cents: 80_000)
    @household.debts.create!(label: "Visa", debt_type: "credit_card", balance_cents: 100_000, minimum_payment_cents: 5_000)
    @household.accounts.create!(label: "Checking", account_type: "checking", balance_cents: 100_000)
    @household.goals.create!(label: "Runway target", goal_type: "runway", record_kind: "policy", target_months: 6)
    manager = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026)
    old_plan = manager.plan_data
    preview = @flow.preview
    assert_equal 0, @household.reload.financial_generation
    assert_equal 2, preview[:review][:counts]["income_sources"]
    receipt = apply(preview)
    assert_equal 1, receipt[:financial_generation]
    assert_equal [], @household.reload.confirmed_setup_fields
    assert_nil @household.primary_goal
    assert_equal 2, @household.historical_income_sources.count
    assert_empty @household.income_sources
    assert_empty @household.debts
    assert_empty @household.accounts
    assert_empty @household.goals
    answer = HouseholdFinance::SavedFinancialRecordsAnswerer.new(@household, message: "What is my income?", year: 2026, month: 10).call
    assert_includes answer.answer, "income is unknown"
    new_plan = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026).plan_data
    context = JSON.parse(HouseholdFinance::MiaContextBuilder.new(@household, annual_plan: new_plan).call, symbolize_names: true)
    assert_nil context[:metrics][:monthly_income]
    assert_equal false, context[:metrics][:monthly_income_known]
    assert_nil context[:metrics][:planned_monthly_outflow]
    assert_nil context[:metrics][:baseline_surplus]
    assert context[:expense_stack_totals].values.all?(&:nil?)
    assert_equal 1, new_plan[:financial_generation]
    assert_equal [], new_plan[:rows]
    assert_equal 2, @household.historical_budget_years.where(year: 2026).count
    @household.income_sources.create!(label: "Salary", source_type: "job", cadence: "monthly", amount_cents: 200_000)
    @household.goals.create!(label: "Runway target", goal_type: "runway", record_kind: "policy", target_months: 3)
    assert_equal 1, @household.income_sources.count
    assert_equal source.id, @household.historical_income_sources.find(source.id).id
    assert_equal old_plan[:rows].size, BudgetCategory.where(household: @household, financial_generation: 0).count
    assert_equal 1, @household.household_audit_events.where(event_type: "financial_restart.applied").count
  end

  test "repeat apply recovers exact receipt without resetting new records" do
    preview = @flow.preview
    receipt = apply(preview)
    @household.income_sources.create!(label: "Real pay", source_type: "job", cadence: "monthly", amount_cents: 10_000)
    assert_equal receipt[:review][:id], @flow.status(review_id: preview[:review][:id])[:latest_review][:id]
    apply(preview)
    assert_equal 1, @household.reload.financial_generation
    assert_equal 1, @household.income_sources.count
    assert_equal 1, @household.household_audit_events.where(event_type: "financial_restart.applied").count
  end

  test "concurrent changes expiry cancellation and missing consent invalidate apply" do
    preview = @flow.preview
    @household.income_sources.create!(label: "New pay", source_type: "job", cadence: "monthly", amount_cents: 10_000)
    assert_raises(HouseholdFinance::FinancialRestart::Flow::StaleReview) { apply(preview) }
    preview = @flow.preview
    travel 16.minutes do
      assert_raises(HouseholdFinance::FinancialRestart::Flow::StaleReview) { apply(preview) }
    end
    preview = @flow.preview
    @flow.cancel(review_id: preview[:review][:id])
    assert_raises(HouseholdFinance::FinancialRestart::Flow::Error) { apply(preview) }
    assert_raises(HouseholdFinance::FinancialRestart::Flow::Error) { @flow.apply(review_id: @flow.preview[:review][:id], confirmation: "yes") }
    assert_equal 0, @household.reload.financial_generation
  end

  test "owner boundary actor-scoped receipts and explicit shared consent" do
    partner = User.create!(clerk_id: "partner_#{SecureRandom.hex(6)}", email: "partner-#{SecureRandom.hex(6)}@example.com", role: "admin", invitation_status: "accepted")
    @household.household_memberships.create!(user: partner, role: "partner")
    partner_flow = HouseholdFinance::FinancialRestart::Flow.new(@household, user: partner)
    assert partner_flow.status[:owner_required]
    assert_raises(HouseholdFinance::FinancialRestart::Flow::OwnerRequired) { partner_flow.preview }
    preview = @flow.preview
    assert_equal 1, preview[:review][:shared_member_count]
    assert_raises(HouseholdFinance::FinancialRestart::Flow::OwnerRequired) { partner_flow.status(review_id: preview[:review][:id]) }
    assert_raises(HouseholdFinance::FinancialRestart::Flow::Error) { apply(preview) }
    @flow.apply(review_id: preview[:review][:id], confirmation: "START OVER", shared_household_acknowledged: true)
    assert_equal 1, @household.reload.financial_generation
  end

  test "old SQL writes and request-inflight creates cannot revive records" do
    debt = @household.debts.create!(label: "Visa", debt_type: "credit_card", balance_cents: 100_000, minimum_payment_cents: 5_000)
    apply(@flow.preview)
    assert_raises(ActiveRecord::StatementInvalid) do
      Debt.transaction(requires_new: true) { debt.update_columns(balance_cents: 200_000) }
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      Debt.transaction(requires_new: true) do
        FinancialPicture.set(household_id: @household.id, generation: 0) do
          @household.debts.create!(label: "Old tab", debt_type: "credit_card", balance_cents: 50_000, minimum_payment_cents: 1_000)
        end
      end
    end
    assert_empty @household.debts
  end

  test "chat and private memories remain visible but cannot seed fresh Mia context" do
    session = @household.chat_sessions.create!(user: @user, active_topic: { "type" => "budget_edit" }, rolling_summary: "Fake salary $9999")
    message = session.chat_messages.create!(role: "user", content: "Fake salary is 9999")
    memory = @household.household_memories.create!(owner_user: @user, category: "goal", status: "user_confirmed", display_value: "Fake balance is 9999", source_kind: "manual_profile")
    apply(@flow.preview)
    assert_equal message.id, session.chat_messages.first.id
    assert_equal [], HouseholdFinance::ConversationTranscriptBuilder.new(session).call
    assert_equal [], HouseholdFinance::MiaMemoryContextBuilder.new(@household, user: @user).call[:memories]
    assert memory.reload.as_api_json(viewer: @user)[:context_paused_by_restart]
    assistant = session.chat_messages.create!(role: "assistant", content: "New setup is missing")
    assert_equal false, HouseholdFinance::ConversationCompactor.new(session, user_message: message, assistant_message: assistant).call
    assert_nil session.reload.rolling_summary
    FinancialPicture.set(household_id: @household.id, generation: 0) do
      assert_raises(HouseholdFinance::Operations::Base::StaleOperation) do
        session.with_lock { session.update!(rolling_summary: "Old fake salary") }
      end
    end
    memory.update!(display_value: "Use brief explanations")
    assert_not memory.reload.as_api_json(viewer: @user)[:context_paused_by_restart]
    assert_equal 1, HouseholdFinance::MiaMemoryContextBuilder.new(@household, user: @user).call[:memories].length
  end

  test "exact fingerprints reject SQL money changes even without updated timestamps" do
    debt = @household.debts.create!(label: "Visa", debt_type: "credit_card", balance_cents: 100_000, minimum_payment_cents: 5_000)
    preview = @flow.preview
    debt.update_columns(balance_cents: 200_000)
    assert_raises(HouseholdFinance::FinancialRestart::Flow::StaleReview) { apply(preview) }
    assert_equal 0, @household.reload.financial_generation
  end

  test "retained source evidence can be erased without changing prior approved financial amounts" do
    document = @household.financial_document_imports.create!(uploaded_by_user: @user, document_kind: "statement", status: "needs_review", filename: "synthetic.pdf", content_type: "application/pdf", byte_size: 1, s3_key: "synthetic.pdf")
    draft = @household.transaction_drafts.create!(financial_document_import: document, occurred_on: Date.current, merchant: "Private source description", total_amount_cents: 1_200, source_type: "statement", status: "pending", raw_input: "Private source", draft_payload: { extracted: "private" })
    apply(@flow.preview)
    FinancialDocuments::SourceEvidenceEraser.call(document)
    assert_nil draft.reload.raw_input
    assert_equal({}, draft.draft_payload)
    assert_equal "Source row", draft.merchant
    assert_equal 1_200, draft.total_amount_cents
    assert_empty @household.transaction_drafts
    assert_raises(ActiveRecord::StatementInvalid) do
      TransactionDraft.transaction(requires_new: true) { draft.update_columns(total_amount_cents: 2_000) }
    end
  end

  private
  def apply(preview)
    @flow.apply(review_id: preview[:review][:id], confirmation: "START OVER")
  end
end
