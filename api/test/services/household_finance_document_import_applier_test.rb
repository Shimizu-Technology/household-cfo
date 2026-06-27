require "test_helper"

class HouseholdFinanceDocumentImportApplierTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(
      clerk_id: "clerk_doc_apply_user",
      email: "doc-apply@example.com",
      role: "participant",
      invitation_status: "accepted"
    )
    @household = Household.create!(created_by_user: @user, name: "Apply Household", primary_goal: "Update numbers")
    @household.household_memberships.create!(user: @user, role: "owner")
    @document_import = FinancialDocumentImport.create!(
      household: @household,
      uploaded_by_user: @user,
      document_kind: "statement",
      status: "needs_review",
      filename: "statement.pdf",
      content_type: "application/pdf",
      byte_size: 100,
      s3_key: "household-cfo/test/statement.pdf",
      extracted_summary: "Statement found income, groceries, cash, and card debt."
    )
  end

  test "applies selected extracted values to household records with lineage" do
    income = @document_import.items.create!(
      target_type: "income_source",
      label: "Primary income",
      amount_cents: 5_000_00,
      cadence: "monthly",
      source_type: "job",
      confidence: "high"
    )
    expense = @document_import.items.create!(
      target_type: "expense_item",
      label: "Groceries",
      amount_cents: 825_00,
      cadence: "monthly",
      stack_key: "discretionary",
      confidence: "medium"
    )
    account = @document_import.items.create!(
      target_type: "account",
      label: "Checking",
      balance_cents: 2_250_00,
      account_type: "checking",
      confidence: "high"
    )
    debt = @document_import.items.create!(
      target_type: "debt",
      label: "Visa",
      balance_cents: 4_820_00,
      payment_cents: 150_00,
      debt_type: "credit_card",
      confidence: "medium"
    )

    result = HouseholdFinance::DocumentImportApplier.new(@document_import, user: @user).call

    assert result.success?, result.errors.join(", ")
    assert_equal 4, result.applied_count
    assert_equal "applied", @document_import.reload.status
    assert_equal @user, @document_import.applied_by_user

    assert_equal 5_000_00, @household.income_sources.find_by!(label: "Primary income").amount_cents
    assert_equal 825_00, @household.expense_items.find_by!(label: "Groceries").amount_cents
    assert_equal 2_250_00, @household.accounts.find_by!(label: "Checking").balance_cents
    assert_equal 4_820_00, @household.debts.find_by!(label: "Visa").balance_cents

    [ income, expense, account, debt ].each do |item|
      item.reload
      assert item.applied?
      assert_equal @user, item.applied_by_user
      assert_not_nil item.applied_record
    end
  end

  test "matches existing household records case-insensitively when applying" do
    @household.income_sources.create!(label: "Primary Income", source_type: "job", amount_cents: 1_000_00, cadence: "monthly")
    @household.expense_items.create!(label: "Groceries", stack_key: "discretionary", amount_cents: 100_00, cadence: "monthly")
    @household.accounts.create!(label: "Checking", account_type: "checking", balance_cents: 250_00)
    @household.debts.create!(label: "Visa", debt_type: "credit_card", balance_cents: 900_00, minimum_payment_cents: 25_00)
    @household.goals.create!(label: "Vehicle Fund", goal_type: "purchase", target_amount_cents: 10_000_00, priority: 3)
    @document_import.items.create!(target_type: "income_source", label: "primary income", amount_cents: 5_500_00, cadence: "monthly", source_type: "job")
    @document_import.items.create!(target_type: "expense_item", label: "groceries", amount_cents: 825_00, cadence: "monthly", stack_key: "discretionary")
    @document_import.items.create!(target_type: "account", label: "checking", balance_cents: 2_250_00, account_type: "checking")
    @document_import.items.create!(target_type: "debt", label: "visa", balance_cents: 4_820_00, payment_cents: 150_00, debt_type: "credit_card")
    @document_import.items.create!(target_type: "goal", label: "vehicle fund", amount_cents: 12_000_00, metadata: { "goal_type" => "purchase" })

    result = HouseholdFinance::DocumentImportApplier.new(@document_import, user: @user).call

    assert result.success?, result.errors.join(", ")
    assert_equal 1, @household.income_sources.where(source_type: "job").count
    assert_equal 5_500_00, @household.income_sources.find_by!(label: "Primary Income").amount_cents
    assert_equal 1, @household.expense_items.where(stack_key: "discretionary").count
    assert_equal 825_00, @household.expense_items.find_by!(label: "Groceries").amount_cents
    assert_equal 1, @household.accounts.where(account_type: "checking").count
    assert_equal 2_250_00, @household.accounts.find_by!(label: "Checking").balance_cents
    assert_equal 1, @household.debts.where(debt_type: "credit_card").count
    assert_equal 4_820_00, @household.debts.find_by!(label: "Visa").balance_cents
    assert_equal 1, @household.goals.where(goal_type: "purchase").count
    assert_equal 12_000_00, @household.goals.find_by!(label: "vehicle fund").target_amount_cents
  end

  test "applies only requested item ids and leaves import partially applied" do
    selected = @document_import.items.create!(
      target_type: "expense_item",
      label: "Dining",
      amount_cents: 300_00,
      cadence: "monthly",
      stack_key: "discretionary",
      confidence: "medium"
    )
    skipped = @document_import.items.create!(
      target_type: "expense_item",
      label: "Travel",
      amount_cents: 900_00,
      cadence: "monthly",
      stack_key: "sinking_expected",
      confidence: "low"
    )

    result = HouseholdFinance::DocumentImportApplier.new(@document_import, user: @user, item_ids: [ selected.id ]).call

    assert result.success?, result.errors.join(", ")
    assert_equal 1, result.applied_count
    assert_equal "partially_applied", @document_import.reload.status
    assert selected.reload.applied?
    assert_not skipped.reload.applied?
    assert_nil @household.expense_items.find_by(label: "Travel")
  end

  test "finalizes partially applied import when remaining items are ignored" do
    selected = @document_import.items.create!(
      target_type: "expense_item",
      label: "Dining",
      amount_cents: 300_00,
      cadence: "monthly",
      stack_key: "discretionary",
      confidence: "medium"
    )
    ignored = @document_import.items.create!(
      target_type: "expense_item",
      label: "Travel",
      amount_cents: 900_00,
      cadence: "monthly",
      stack_key: "sinking_expected",
      confidence: "low"
    )

    first_result = HouseholdFinance::DocumentImportApplier.new(@document_import, user: @user, item_ids: [ selected.id ]).call
    assert first_result.success?, first_result.errors.join(", ")
    assert_equal "partially_applied", @document_import.reload.status

    ignored.update!(ignored: true, selected: false)
    final_result = HouseholdFinance::DocumentImportApplier.new(@document_import, user: @user).call

    assert final_result.success?, final_result.errors.join(", ")
    assert_equal 0, final_result.applied_count
    assert_equal "applied", @document_import.reload.status
    assert selected.reload.applied?
    assert_not ignored.reload.applied?
  end

  test "unselected unresolved items keep import reviewable instead of finalizing" do
    @document_import.items.create!(
      target_type: "expense_item",
      label: "Travel",
      amount_cents: 900_00,
      cadence: "monthly",
      stack_key: "sinking_expected",
      confidence: "low",
      selected: false
    )

    result = HouseholdFinance::DocumentImportApplier.new(@document_import, user: @user).call

    assert_not result.success?
    assert_equal "No selected extracted values to apply", result.errors.first
    assert_equal "needs_review", @document_import.reload.status
  end

  test "stale import instance cannot mark reprocessed document applied" do
    @document_import.items.create!(
      target_type: "expense_item",
      label: "Dining",
      amount_cents: 300_00,
      cadence: "monthly",
      stack_key: "discretionary",
      confidence: "medium"
    )
    FinancialDocumentImportItem.where(financial_document_import_id: @document_import.id).delete_all
    FinancialDocumentImport.where(id: @document_import.id).update_all(status: "uploaded", applied_at: nil, updated_at: Time.current)

    result = HouseholdFinance::DocumentImportApplier.new(@document_import, user: @user).call

    assert_not result.success?
    assert_equal "Document import is not ready for review", result.errors.first
    @document_import.reload
    assert_equal "uploaded", @document_import.status
    assert_nil @document_import.applied_at
    assert_nil @document_import.applied_by_user
  end

  test "profile note imports keep household profile notes bounded" do
    profile = @household.household_profile || @household.create_household_profile!
    profile.update!(notes: "older note\n" * 300)
    @document_import.items.create!(
      target_type: "profile_note",
      label: "Document observation",
      evidence: "The uploaded document had a useful coaching note.",
      confidence: "medium"
    )

    result = HouseholdFinance::DocumentImportApplier.new(@document_import, user: @user).call

    assert result.success?, result.errors.join(", ")
    notes = profile.reload.notes
    assert_operator notes.length, :<=, HouseholdFinance::DocumentImportApplier::MAX_PROFILE_NOTES_LENGTH
    assert_includes notes, HouseholdFinance::DocumentImportApplier::PROFILE_NOTES_TRIM_MARKER
    assert_includes notes, "Document observation"
    assert_includes notes, "useful coaching note"
  end
end
