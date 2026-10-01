require "test_helper"

class HouseholdFinanceMiaDebtActionDraftsTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(clerk_id: "mia_debt_#{SecureRandom.hex(4)}", email: "mia-debt-#{SecureRandom.hex(4)}@example.com", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    @manager = HouseholdFinance::AnnualBudgetManager.new(@household, year: Date.current.year)
  end

  test "Mia prepares and applies a typed debt create only after review" do
    result = build_command(type: "create_debt", debt_name: "Visa", debt_type: "credit_card", balance: "3100", minimum_payment: "175", interest_rate_percent: "28.9")

    assert_equal "debt_plan", result.proposal.draft_type
    assert_empty @household.debts
    draft = persist(result.proposal)
    item = draft.mia_action_items.sole
    assert_equal "debt.record.create", item.operation_key
    assert_equal 310_000, item.prepared_operation.dig("normalized_input", "balance_cents")
    review = HouseholdFinance::MiaActionDraftPresenter.new(draft).call.fetch(:items).sole.fetch(:review_fields)
    assert_equal "$3,100.00", review.find { |field| field.fetch(:label) == "Balance" }.fetch(:after)
    assert_equal "28.9%", review.find { |field| field.fetch(:label) == "APR" }.fetch(:after)

    applied = HouseholdFinance::MiaActionDraftApplier.new(draft, user: @user).call
    assert applied.success?, applied.errors.to_sentence
    debt = @household.debts.find_by!(label: "Visa")
    assert_equal "mia", debt.source_type
    assert_equal 310_000, debt.balance_cents
    assert_equal 17_500, debt.minimum_payment_cents
  end

  test "Mia refuses an ambiguous debt name" do
    @household.debts.create!(label: "Loan", debt_type: "auto_loan", balance_cents: 100_000)
    @household.debts.create!(label: "Loan", debt_type: "student_loan", balance_cents: 200_000)

    result = build_command(type: "update_debt", debt_name: "Loan", balance: "1500")

    assert_nil result.proposal
    assert_includes result.response, "could not safely match"
  end

  test "Mia balance-only update preserves an existing minimum and APR" do
    debt = @household.debts.create!(
      label: "Visa", debt_type: "credit_card", balance_cents: 310_000,
      minimum_payment_cents: 17_500, interest_rate_percent: 28.9
    )

    result = build_command(
      type: "update_debt", debt_id: debt.id, debt_name: "Visa", amount: "2900",
      minimum_payment: "", interest_rate_percent: ""
    )

    item = persist(result.proposal).mia_action_items.sole
    normalized = item.prepared_operation.fetch("normalized_input")
    assert_equal 290_000, normalized.fetch("balance_cents")
    refute normalized.key?("minimum_payment_cents")
    refute normalized.key?("interest_rate_percent")
    assert_equal 17_500, item.after_snapshot.fetch("minimum_payment_cents")
    assert_equal 28.9, item.after_snapshot.fetch("interest_rate_percent")
  end

  test "Mia review shows known zero and unknown debt transitions" do
    unknown = @household.debts.create!(
      label: "Unknown card", debt_type: "credit_card", balance_cents: 0,
      balance_known: false, minimum_payment_cents: 0, minimum_payment_known: false
    )
    known = @household.debts.create!(
      label: "Known card", debt_type: "credit_card", balance_cents: 0,
      balance_known: true, minimum_payment_cents: 0, minimum_payment_known: true
    )

    known_zero_draft = persist(build_command(type: "update_debt", debt_id: unknown.id, debt_name: unknown.label, amount: "0", minimum_payment: "0").proposal)
    unknown_draft = persist(build_command(type: "update_debt", debt_id: known.id, debt_name: known.label, amount: "unknown", minimum_payment: "unknown").proposal)
    known_zero_fields = HouseholdFinance::MiaActionDraftPresenter.new(known_zero_draft).call.fetch(:items).sole.fetch(:review_fields)
    unknown_fields = HouseholdFinance::MiaActionDraftPresenter.new(unknown_draft).call.fetch(:items).sole.fetch(:review_fields)

    assert_equal [ "Not entered", "$0.00" ], known_zero_fields.find { |field| field.fetch(:label) == "Balance" }.values_at(:before, :after)
    assert_equal [ "Not entered", "$0.00" ], known_zero_fields.find { |field| field.fetch(:label) == "Monthly minimum" }.values_at(:before, :after)
    assert_equal [ "$0.00", "Not entered" ], unknown_fields.find { |field| field.fetch(:label) == "Balance" }.values_at(:before, :after)
    assert_equal [ "$0.00", "Not entered" ], unknown_fields.find { |field| field.fetch(:label) == "Monthly minimum" }.values_at(:before, :after)
  end

  test "Mia archive preserves the record and can be restored through another review" do
    debt = @household.debts.create!(label: "Auto", debt_type: "auto_loan", balance_cents: 500_000, minimum_payment_cents: 25_000)
    archive = persist(build_command(type: "archive_debt", debt_id: debt.id, debt_name: "Auto").proposal)
    result = HouseholdFinance::MiaActionDraftApplier.new(archive, user: @user).call
    assert result.success?, result.errors.to_sentence
    assert_not debt.reload.active?

    restore = persist(build_command(type: "restore_debt", debt_id: debt.id, debt_name: "Auto").proposal)
    result = HouseholdFinance::MiaActionDraftApplier.new(restore, user: @user).call
    assert result.success?, result.errors.to_sentence
    assert debt.reload.active?
  end

  test "Mia tracking review does not infer balance from the minimum" do
    result = build_command(type: "update_debt_tracking", debt_tracking_mode: "summary", amount: "unknown", minimum_payment: "250")
    draft = persist(result.proposal)
    item = draft.mia_action_items.sole
    assert_equal false, item.prepared_operation.dig("normalized_input", "summary_balance_known")
    assert_equal 25_000, item.prepared_operation.dig("normalized_input", "summary_minimum_payment_cents")

    applied = HouseholdFinance::MiaActionDraftApplier.new(draft, user: @user).call
    assert applied.success?, applied.errors.to_sentence
    portfolio = HouseholdFinance::DebtPortfolio.new(@household.reload)
    assert_not portfolio.balance_known?
    assert portfolio.minimum_payment_known?
    assert_equal 0, portfolio.total_balance_cents
    assert_equal 25_000, portfolio.monthly_minimum_cents
  end

  test "Mia tracking review shows the canonical financial impact of switching modes" do
    @household.debts.create!(
      label: "Visa", debt_type: "credit_card", balance_cents: 310_000,
      minimum_payment_cents: 17_500
    )
    @household.household_profile.update!(
      debt_tracking_mode: "summary", debt_summary_balance_cents: 900_000,
      debt_summary_minimum_payment_cents: 40_000,
      debt_summary_balance_known: true, debt_summary_minimum_payment_known: true
    )

    draft = persist(build_command(type: "update_debt_tracking", debt_tracking_mode: "individual").proposal)
    review = HouseholdFinance::MiaActionDraftPresenter.new(draft).call.fetch(:items).sole.fetch(:review_fields)

    assert_equal [ "$9,000.00", "$3,100.00" ], review.find { |field| field.fetch(:label) == "Planning balance" }.values_at(:before, :after)
    assert_equal [ "$400.00", "$175.00" ], review.find { |field| field.fetch(:label) == "Planning monthly minimum" }.values_at(:before, :after)
    assert_equal [ "1", "1" ], review.find { |field| field.fetch(:label) == "Active individual records" }.values_at(:before, :after)
  end

  private

  def build_command(command)
    HouseholdFinance::MiaActionDraftBuilder.new(
      @household, user: @user, annual_budget_manager: @manager,
      raw_input: "model resolved debt command", command: command
    ).call
  end

  def persist(proposal)
    session = @household.chat_sessions.find_or_create_by!(user: @user) { |record| record.title = "Ask Mia" }
    proposal.create_draft!(
      source_chat_message: session.chat_messages.create!(role: "user", content: "Please update my debt"),
      assistant_chat_message: session.chat_messages.create!(role: "assistant", content: "Review this change")
    )
  end
end
