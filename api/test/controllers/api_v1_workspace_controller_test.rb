require "test_helper"
require_relative "../support/persona_test_helper"

class ApiV1WorkspaceControllerTest < ActionDispatch::IntegrationTest
  include PersonaTestHelper
  test "mia attachment route copy safely handles a legacy import without a document kind" do
    legacy_import = Struct.new(:metadata, :document_kind).new({}, nil)
    route_line = Api::V1::MiaMessagesController.new.send(:attached_document_route_line, legacy_import)

    assert_equal "I recognized this as other and routed it to private import history.", route_line
  end

  test "mia attachment route copy follows the reviewable results rather than a mismatched selected slot" do
    user = create_user(email: "upload-result@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    document_import = household.financial_document_imports.create!(
      uploaded_by_user: user,
      document_kind: "receipt",
      status: "needs_review",
      filename: "profile-screenshot.png",
      content_type: "image/png",
      byte_size: 100,
      s3_key: "test/profile-screenshot.png",
      metadata: {
        "declared_document_kind" => "receipt",
        "routing_resolved_kind" => "receipt",
        "routing_destination" => "transaction_review"
      }
    )
    document_import.items.create!(target_type: "expense_item", label: "Fixed essentials", amount_cents: 310_000, confidence: "high")

    route_line = Api::V1::MiaMessagesController.new.send(:attached_document_route_line, document_import)

    assert_equal "You selected this as receipt. I checked the file and routed the reviewable results I actually found to household setup review.", route_line
  end

  test "mia attachment route copy names both review destinations when extraction produces both result types" do
    user = create_user(email: "mixed-upload-result@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    document_import = household.financial_document_imports.create!(
      uploaded_by_user: user,
      document_kind: "statement",
      status: "needs_review",
      filename: "mixed-statement.csv",
      content_type: "text/csv",
      byte_size: 100,
      s3_key: "test/mixed-statement.csv",
      metadata: { "routing_resolved_kind" => "statement", "routing_destination" => "transaction_review" }
    )
    document_import.items.create!(target_type: "account", label: "Checking", balance_cents: 500_000, confidence: "high")
    document_import.transaction_drafts.create!(
      household: household,
      occurred_on: Date.new(2026, 8, 1),
      merchant: "Market",
      total_amount_cents: 8_425,
      source_type: "statement",
      status: "pending",
      raw_input: "Statement row"
    )

    route_line = Api::V1::MiaMessagesController.new.send(:attached_document_route_line, document_import)

    assert_equal "I recognized this as statement and routed it to pending transaction review and household setup review.", route_line
  end

  test "mia attachment route copy sends fully resolved extraction results to import history" do
    user = create_user(email: "resolved-upload-result@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    document_import = household.financial_document_imports.create!(
      uploaded_by_user: user,
      document_kind: "statement",
      status: "applied",
      filename: "resolved-statement.csv",
      content_type: "text/csv",
      byte_size: 100,
      s3_key: "test/resolved-statement.csv",
      applied_at: Time.current,
      metadata: { "routing_resolved_kind" => "statement", "routing_destination" => "transaction_review" }
    )
    document_import.items.create!(
      target_type: "account",
      label: "Checking",
      balance_cents: 500_000,
      confidence: "high",
      selected: true,
      applied_at: Time.current
    )
    document_import.transaction_drafts.create!(
      household: household,
      occurred_on: Date.new(2026, 8, 1),
      merchant: "Market",
      total_amount_cents: 8_425,
      source_type: "statement",
      status: "confirmed",
      raw_input: "Statement row"
    )

    route_line = Api::V1::MiaMessagesController.new.send(:attached_document_route_line, document_import)

    assert_equal "I recognized this as statement and kept the resolved results in private import history.", route_line
  end

  test "mia attachment summary names the actual destinations in a mixed batch" do
    document_import = Struct.new(:metadata, :document_kind)
    imports = [
      document_import.new({ "routing_destination" => "transaction_review" }, "receipt"),
      document_import.new({ "routing_destination" => "private_document_review" }, "other")
    ]

    summary = Api::V1::MiaMessagesController.new.send(:attached_documents_route_summary, imports)

    assert_equal "I routed the uploads to pending transaction review and private import history.", summary
    assert_not_includes summary, "household setup review"
  end

  test "mia attachment summary uses complete fallback copy for malformed legacy conflicts" do
    document_import = Struct.new(:metadata, :document_kind, :content_type)
    imports = [
      document_import.new({ "routing_requires_confirmation" => true, "routing_conflict_reason" => "participant_signals" }, "receipt", "image/png"),
      document_import.new({ "routing_requires_confirmation" => true, "routing_conflict_reason" => "mia_detection" }, "statement", "application/pdf")
    ]

    summary = Api::V1::MiaMessagesController.new.send(:attached_documents_route_summary, imports)

    assert_includes summary, "your message described receipt, selected type was another document type"
    assert_includes summary, "you described statement, Mia detected another document type"
  end

  test "workspace creates an empty household for an authenticated participant" do
    user = create_user(email: "participant@example.com")

    get "/api/v1/workspace", headers: auth_headers(user)

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "real", body.fetch("workspace").fetch("mode")
    assert_equal "participant's Household", body.fetch("profile").fetch("household").fetch("name")
    assert_equal 0, body.fetch("dashboard").fetch("summary").fetch("monthly_income")
  end

  test "workspace setup saves real household numbers and recalculates dashboard" do
    user = create_user(email: "mel@example.com", first_name: "Mel")

    assert_difference("HouseholdAuditEvent.where(event_type: 'workspace.setup_saved').count", 1) do
      patch "/api/v1/workspace/setup",
            params: {
              workspace: {
                household_name: "Mendiola Household",
                primary_goal: "Decide if the purse is in the cards.",
                primary_income: 8_000,
                business_income: 1_200,
                fixed_expenses: 4_500,
                flexible_spend: 1_300,
                expected_sinking_fund: 500,
                unexpected_sinking_fund: 300,
                emergency_fund: 18_000,
                other_assets: 12_000,
                target_runway_months: 6
              }
            },
            headers: auth_headers(user),
            as: :json
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "Mendiola Household", body.fetch("profile").fetch("household").fetch("name")
    assert_equal 9_200, body.fetch("dashboard").fetch("summary").fetch("monthly_income")
    assert_equal 6_600, body.fetch("budget").fetch("total_monthly_outflow")
    assert_equal 2_600, body.fetch("budget").fetch("baseline_surplus")
    annual_plan = body.fetch("budget").fetch("annual_plan")
    current_month = annual_plan.fetch("annual_outlook").fetch("months").fetch(Date.current.month - 1)
    assert_equal 0, annual_plan.fetch("monthly_debt_minimums")
    refute annual_plan.fetch("monthly_debt_minimums_known")
    assert_equal 6_600, current_month.fetch("category_plan")
    assert_equal 0, current_month.fetch("debt_minimums")
    assert_equal 6_600, current_month.fetch("planned_outflow")
    assert_equal 2_600, current_month.fetch("baseline_surplus")
    refute body.fetch("dashboard").fetch("summary").fetch("readiness_available")
    assert_nil body.fetch("dashboard").fetch("summary").fetch("runway_months")
    setup_audit = user.households.first.household_audit_events.find_by!(event_type: "workspace.setup_saved")
    assert_equal({ "setup_complete" => true }, setup_audit.metadata)
  end

  test "manual setup uses typed household operations and replays one idempotent request" do
    user = create_user(email: "typed-manual-setup@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    headers = auth_headers(user).merge("Idempotency-Key" => "manual-typed-setup-1")
    request = {
      workspace: {
        household_name: "Typed Household", primary_goal: "Build runway", primary_income: 6_500,
        fixed_expenses: 2_700, flexible_spend: 800, emergency_fund: 9_000, target_runway_months: 5
      }
    }

    assert_difference("HouseholdAuditEvent.where(event_type: 'workspace.setup_saved').count", 1) do
      patch "/api/v1/workspace/setup", params: request, headers: headers, as: :json
    end

    assert_response :success
    executions = household.household_operation_executions.order(:id)
    operation_keys = executions.pluck(:operation_key)
    assert_includes operation_keys, "profile.household.update"
    assert_includes operation_keys, "income.source.create"
    assert operation_keys.any? { |key| key.in?(%w[budget.category.create budget.allocation.set]) }
    assert_includes operation_keys, "account.record.create"
    assert_includes operation_keys, "goal.runway_policy.update"
    assert_includes operation_keys, "goal.transition_policy.update"
    assert_equal "profile.setup_confirmation.update", executions.find_by!(idempotency_key: "manual-typed-setup-1").operation_key
    assert_equal [ "manual" ], household.household_operation_executions.distinct.pluck(:source)
    assert_equal [ "Build runway" ], household.goals.where(goal_type: "transition").pluck(:label)

    execution_count = executions.count
    audit_count = household.household_audit_events.where(event_type: "workspace.setup_saved").count
    patch "/api/v1/workspace/setup", params: request, headers: headers, as: :json

    assert_response :success
    assert_equal execution_count, executions.reload.count
    assert_equal audit_count, household.household_audit_events.where(event_type: "workspace.setup_saved").count

    assert_no_changes -> { household.reload.name } do
      patch "/api/v1/workspace/setup",
        params: { workspace: request.fetch(:workspace).merge(household_name: "Conflicting Household") },
        headers: headers,
        as: :json
    end
    assert_response :conflict
    assert_includes response.parsed_body.fetch("errors").join, "idempotency key"
  end

  test "manual setup repairs a changed allocation even when the legacy expense total matches" do
    user = create_user(email: "setup-allocation-drift@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    manager = HouseholdFinance::AnnualBudgetManager.new(household, year: Date.current.year)
    category = manager.create_category!(name: "Fixed essentials", stack_key: "non_discretionary", monthly_amount: 1_000)
    changed = category.budget_allocations.joins(:budget_period)
      .find_by!(budget_periods: { starts_on: Date.new(Date.current.year, 6, 1) })
    changed.update!(planned_amount_cents: 125_000)

    patch "/api/v1/workspace/setup",
      params: { workspace: { fixed_expenses: 1_000 } },
      headers: auth_headers(user).merge("Idempotency-Key" => "repair-setup-allocation-drift"),
      as: :json

    assert_response :success
    assert_equal Array.new(12, 100_000), category.budget_allocations.joins(:budget_period)
      .where(budget_periods: { starts_on: Date.new(Date.current.year, 1, 1)..Date.new(Date.current.year, 12, 31) })
      .order("budget_periods.starts_on").pluck(:planned_amount_cents)
    assert household.household_operation_executions.exists?(operation_key: "budget.allocation.set")
  end

  test "manual setup keeps max-length child idempotency keys unique and conflict-safe" do
    user = create_user(email: "typed-manual-max-key@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    key = "k" * 200
    headers = auth_headers(user).merge("Idempotency-Key" => key)
    request = { workspace: { household_name: "Long Key Household", primary_income: 5_800, fixed_expenses: 2_400 } }

    patch "/api/v1/workspace/setup", params: request, headers: headers, as: :json

    assert_response :success
    keys = household.household_operation_executions.pluck(:idempotency_key)
    assert_equal keys.length, keys.uniq.length
    assert keys.all? { |stored| stored.length <= 200 }
    first_count = keys.length
    household.update!(name: "Later manual name")

    patch "/api/v1/workspace/setup", params: request, headers: headers, as: :json
    assert_response :success
    assert_equal first_count, household.household_operation_executions.count
    assert_equal "Later manual name", household.reload.name

    patch "/api/v1/workspace/setup",
      params: { workspace: request.fetch(:workspace).merge(primary_income: 5_900) },
      headers: headers,
      as: :json
    assert_response :conflict
    assert_equal 580_000, household.income_sources.find_by!(source_type: "job").amount_cents
  end

  test "manual setup clearing removes explicit confirmations through the typed confirmation operation" do
    user = create_user(email: "typed-manual-clear-confirmation@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    household.update!(primary_goal: "Leave work safely", confirmed_setup_fields: %w[primary_goal emergency_fund])
    household.accounts.create!(
      label: "Emergency fund", account_type: "emergency_fund", balance_cents: 800_000,
      balance_known: true, balance_as_of_on: Date.current, source_type: "setup"
    )

    patch "/api/v1/workspace/setup",
      params: { workspace: { primary_goal: "", emergency_fund: "" } },
      headers: auth_headers(user).merge("Idempotency-Key" => "manual-clear-confirmations"),
      as: :json

    assert_response :success
    assert_nil household.reload.primary_goal
    assert_empty household.confirmed_setup_fields & %w[primary_goal emergency_fund]
    refute household.accounts.find_by!(account_type: "emergency_fund").balance_known?
    confirmation = household.household_operation_executions.find_by!(idempotency_key: "manual-clear-confirmations")
    assert_equal %w[emergency_fund primary_goal], confirmation.normalized_input.fetch("unconfirmed_fields")
  end

  test "five-field first-session setup leaves optional assets unknown" do
    user = create_user(email: "five-field-setup@example.com", first_name: "Mel")

    patch "/api/v1/workspace/setup",
      params: {
        workspace: {
          household_name: "Five Field Household",
          primary_goal: "Build a calm monthly plan.",
          primary_income: 6_200,
          fixed_expenses: 2_800,
          flexible_spend: 0
        }
      },
      headers: auth_headers(user),
      as: :json

    assert_response :success
    body = response.parsed_body
    household = user.households.first

    assert_empty household.accounts
    assert_nil body.dig("workspace", "setup_values", "emergency_fund")
    assert_nil body.dig("workspace", "setup_values", "other_assets")
    refute body.dig("workspace", "asset_portfolio", "liquid_balance_known")
    assert_equal 0, body.dig("workspace", "asset_portfolio", "liquid_known_count")
    assert_nil body.dig("dashboard", "summary", "runway_months")
  end

  test "workspace setup audit failure rolls back changes and returns a safe retry response" do
    user = create_user(email: "setup-audit-failure@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    original_name = household.name
    reject_setup_audit = lambda do |audit_event|
      audit_event.errors.add(:base, "Forced setup audit failure") if audit_event.event_type == "workspace.setup_saved"
    end
    HouseholdAuditEvent.set_callback(:validation, :before, reject_setup_audit)

    assert_no_difference("HouseholdAuditEvent.where(event_type: 'workspace.setup_saved').count") do
      patch "/api/v1/workspace/setup",
            params: { workspace: { household_name: "Name that must roll back" } },
            headers: auth_headers(user),
            as: :json
    end

    assert_response :service_unavailable
    assert_equal [ "We couldn't save your setup right now. Please try again." ], JSON.parse(response.body).fetch("errors")
    assert_equal original_name, household.reload.name
    assert_not_includes response.body, "Forced setup audit failure"
  ensure
    HouseholdAuditEvent.skip_callback(:validation, :before, reject_setup_audit) if reject_setup_audit
  end

  test "workspace setup partial patch preserves omitted financial values" do
    user = create_user(email: "partial-setup@example.com")

    patch "/api/v1/workspace/setup",
          params: {
            workspace: {
              primary_income: 8_000,
              fixed_expenses: 4_500,
              emergency_fund: 18_000,
              target_runway_months: 12
            }
          },
          headers: auth_headers(user),
          as: :json
    household = user.households.first
    household.household_profile.update!(
      debt_tracking_mode: "summary", debt_summary_balance_cents: 700_000,
      debt_summary_minimum_payment_cents: 70_000,
      debt_summary_balance_known: true, debt_summary_minimum_payment_known: true
    )
    patch "/api/v1/workspace/setup",
          params: { workspace: { household_name: "Renamed Household" } },
          headers: auth_headers(user),
          as: :json

    assert_response :success
    assert_equal "Renamed Household", household.reload.name
    assert_equal 800_000, household.income_sources.find_by!(source_type: "job").amount_cents
    assert_equal 450_000, household.expense_items.find_by!(stack_key: "non_discretionary").amount_cents
    assert_equal 1_800_000, household.accounts.find_by!(account_type: "emergency_fund").balance_cents
    profile = household.household_profile.reload
    assert_equal "summary", profile.debt_tracking_mode
    assert_equal 700_000, profile.debt_summary_balance_cents
    assert_equal 12, household.goals.find_by!(goal_type: "runway").target_months

    patch "/api/v1/workspace/setup",
          params: { workspace: { debt_payment: 900 } },
          headers: auth_headers(user),
          as: :json

    assert_response :success
    profile.reload
    assert_equal 700_000, profile.debt_summary_balance_cents
    assert_equal 70_000, profile.debt_summary_minimum_payment_cents
  end

  test "workspace setup does not duplicate document-derived detail rows when values are unchanged" do
    user = create_user(email: "document-detail-setup@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    household.income_sources.create!(label: "Primary salary", source_type: "job", amount_cents: 620_000, cadence: "monthly")
    household.expense_items.create!(label: "Rent", stack_key: "non_discretionary", amount_cents: 220_000, cadence: "monthly")
    household.expense_items.create!(label: "Utilities", stack_key: "non_discretionary", amount_cents: 36_000, cadence: "monthly")
    visa = household.debts.create!(label: "Visa card", debt_type: "credit_card", balance_cents: 340_000, minimum_payment_cents: 17_500)
    mastercard = household.debts.create!(label: "Mastercard", debt_type: "credit_card", balance_cents: 120_000, minimum_payment_cents: 6_000)

    get "/api/v1/workspace", headers: auth_headers(user)
    setup_values = JSON.parse(response.body).fetch("workspace").fetch("setup_values")

    assert_no_difference("IncomeSource.count") do
      assert_no_difference("ExpenseItem.count") do
        assert_no_difference("Debt.count") do
          patch "/api/v1/workspace/setup",
            params: { workspace: setup_values },
            headers: auth_headers(user),
            as: :json
        end
      end
    end

    assert_response :success
    assert_equal 620_000, household.income_sources.where(source_type: "job", active: true).sum(:amount_cents)
    assert_equal 256_000, household.expense_items.where(stack_key: "non_discretionary", active: true).sum(:amount_cents)
    assert_equal 460_000, household.debts.where(debt_type: "credit_card").sum(:balance_cents)
    assert_equal 340_000, visa.reload.balance_cents
    assert_equal 17_500, visa.minimum_payment_cents
    assert_equal 120_000, mastercard.reload.balance_cents
    assert_equal 6_000, mastercard.minimum_payment_cents
  end

  test "workspace setup rejects ambiguous aggregate income without changing detailed rows" do
    user = create_user(email: "document-detail-distribution@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    salary = household.income_sources.create!(label: "Primary salary", source_type: "job", amount_cents: 620_000, cadence: "monthly")
    overtime = household.income_sources.create!(label: "Overtime", source_type: "job", amount_cents: 100_000, cadence: "monthly")
    rent = household.expense_items.create!(label: "Rent", stack_key: "non_discretionary", amount_cents: 220_000, cadence: "monthly")
    utilities = household.expense_items.create!(label: "Utilities", stack_key: "non_discretionary", amount_cents: 36_000, cadence: "monthly")

    assert_no_difference("IncomeSource.count") do
      assert_no_difference("ExpenseItem.count") do
        patch "/api/v1/workspace/setup",
          params: { workspace: { primary_income: 6_000, fixed_expenses: 2_000 } },
          headers: auth_headers(user),
          as: :json
      end
    end

    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body).fetch("errors").join, "multiple saved sources"
    assert_nil household.income_sources.find_by(label: "Primary income")
    assert_nil household.expense_items.find_by(label: "Fixed essentials")
    assert_equal "Primary salary", salary.reload.label
    assert_equal "Overtime", overtime.reload.label
    assert_equal "Rent", rent.reload.label
    assert_equal "Utilities", utilities.reload.label
    assert salary.active?
    assert overtime.active?
    assert rent.active?
    assert utilities.active?
    current_income = household.income_sources.where(source_type: "job", active: true).sum do |source|
      HouseholdFinance::IncomeTimeline.recurring_monthly_cents(source, on: Date.current)
    end
    assert_equal 720_000, current_income
    assert_equal 620_000, salary.amount_cents
    assert_equal 100_000, overtime.amount_cents
    assert_equal 256_000, household.expense_items.where(stack_key: "non_discretionary", active: true).sum(:amount_cents)
  end

  test "workspace income edits take effect now without rewriting the historical baseline" do
    travel_to Date.new(2026, 8, 25) do
      user = create_user(email: "effective-income-edit@example.com")
      household = HouseholdFinance::WorkspaceResolver.new(user).household
      source = household.income_sources.create!(
        label: "Primary salary",
        source_type: "job",
        amount_cents: 500_000,
        cadence: "monthly"
      )

      patch "/api/v1/workspace/setup",
            params: { workspace: { primary_income: 7_000 } },
            headers: auth_headers(user),
            as: :json

      assert_response :success
      assert_equal 500_000, source.reload.amount_cents
      assert_equal 500_000, HouseholdFinance::IncomeTimeline.recurring_monthly_cents(source, on: Date.new(2026, 7, 31))
      assert_equal 700_000, HouseholdFinance::IncomeTimeline.recurring_monthly_cents(source, on: Date.new(2026, 8, 31))
      assert_equal 7_000, JSON.parse(response.body).dig("workspace", "setup_values", "primary_income")
    end
  end

  test "clearing current income preserves prior budget history and future scheduled changes" do
    travel_to Date.new(2026, 8, 25) do
      user = create_user(email: "clear-current-income@example.com")
      household = HouseholdFinance::WorkspaceResolver.new(user).household
      source = household.income_sources.create!(
        label: "Primary salary",
        source_type: "job",
        amount_cents: 500_000,
        cadence: "monthly"
      )
      source.income_schedule_entries.create!(
        entry_type: "recurring_change",
        amount_cents: 650_000,
        cadence: "monthly",
        effective_on: Date.new(2026, 10, 1)
      )

      patch "/api/v1/workspace/setup",
            params: { workspace: { primary_income: 0 } },
            headers: auth_headers(user),
            as: :json

      assert_response :success
      assert source.reload.active?
      assert_equal 500_000, HouseholdFinance::IncomeTimeline.recurring_monthly_cents(source, on: Date.new(2026, 7, 31))
      assert_equal 0, HouseholdFinance::IncomeTimeline.recurring_monthly_cents(source, on: Date.new(2026, 8, 31))
      assert_equal 650_000, HouseholdFinance::IncomeTimeline.recurring_monthly_cents(source, on: Date.new(2026, 10, 31))
      assert_equal 0, JSON.parse(response.body).dig("workspace", "setup_values", "primary_income")
    end
  end

  test "workspace setup rejects malformed money and rolls back every submitted change" do
    user = create_user(email: "malformed-money@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    original_name = household.name
    source = household.income_sources.create!(
      label: "Primary salary",
      source_type: "job",
      amount_cents: 500_000,
      cadence: "monthly"
    )

    patch "/api/v1/workspace/setup",
          params: { workspace: { household_name: "Should roll back", primary_income: "five thousand" } },
          headers: auth_headers(user),
          as: :json

    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body).fetch("errors"), "Primary income must be a number with no more than two decimal places"
    assert_equal original_name, household.reload.name
    assert_equal 500_000, source.reload.amount_cents
    assert_empty source.income_schedule_entries
  end

  test "workspace setup rejects an invalid runway target instead of silently saving a default" do
    user = create_user(email: "invalid-runway@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household

    patch "/api/v1/workspace/setup",
          params: { workspace: { target_runway_months: "not a number" } },
          headers: auth_headers(user),
          as: :json

    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body).fetch("errors"), "Target runway months must be a positive number"
    assert_empty household.goals.where(goal_type: "runway")
  end

  test "workspace setup ignores legacy aggregate debt fields while individual debt tracking is active" do
    user = create_user(email: "document-debt-payment@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    debt = household.debts.create!(label: "Visa card", debt_type: "credit_card", balance_cents: 340_000, minimum_payment_cents: 0)

    patch "/api/v1/workspace/setup",
      params: { workspace: { credit_card_debt: 3_400, debt_payment: 175 } },
      headers: auth_headers(user),
      as: :json

    assert_response :success
    assert_equal 1, household.debts.where(debt_type: "credit_card").count
    assert_equal 340_000, debt.reload.balance_cents
    assert_equal 0, debt.minimum_payment_cents
  end

  test "workspace setup ignores legacy aggregate debt fields across multiple detailed debts" do
    user = create_user(email: "multi-document-debt@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    visa = household.debts.create!(label: "Visa card", debt_type: "credit_card", balance_cents: 340_000, minimum_payment_cents: 17_500)
    mastercard = household.debts.create!(label: "Mastercard", debt_type: "credit_card", balance_cents: 120_000, minimum_payment_cents: 6_000)

    assert_no_difference("Debt.count") do
      patch "/api/v1/workspace/setup",
        params: { workspace: { credit_card_debt: 4_000, debt_payment: 200 } },
        headers: auth_headers(user),
        as: :json
    end

    assert_response :success
    assert_equal 2, household.debts.where(debt_type: "credit_card").count
    assert_equal 340_000, visa.reload.balance_cents
    assert_equal 120_000, mastercard.reload.balance_cents
    assert_equal 23_500, household.debts.where(debt_type: "credit_card").sum(:minimum_payment_cents)
  end

  test "workspace setup round trip preserves unknown debt instead of certifying zero" do
    user = create_user(email: "clear-debt@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    household.household_profile.update!(
      debt_tracking_mode: "summary", debt_summary_balance_cents: 0,
      debt_summary_minimum_payment_cents: 0,
      debt_summary_balance_known: false, debt_summary_minimum_payment_known: false
    )

    get "/api/v1/workspace", headers: auth_headers(user)
    setup_values = response.parsed_body.dig("workspace", "setup_values")
    assert_nil setup_values.fetch("credit_card_debt")
    assert_nil setup_values.fetch("debt_payment")

    patch "/api/v1/workspace/setup",
          params: { workspace: setup_values },
          headers: auth_headers(user),
          as: :json

    assert_response :success
    profile = household.household_profile.reload
    refute profile.debt_summary_balance_known?
    refute profile.debt_summary_minimum_payment_known?
    assert_nil response.parsed_body.dig("workspace", "setup_values", "credit_card_debt")
    assert_nil response.parsed_body.dig("workspace", "setup_values", "debt_payment")
    refute response.parsed_body.dig("dashboard", "summary", "readiness_available")
  end

  test "workspace setup values keep other assets separate from typed accounts" do
    user = create_user(email: "assets@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    household.accounts.create!(label: "Emergency fund", account_type: "emergency_fund", balance_cents: 500_000)
    household.accounts.create!(label: "Other assets", account_type: "other", balance_cents: 1_200_000)
    household.accounts.create!(label: "Investment account", account_type: "investment", balance_cents: 3_000_000)
    household.household_profile.update!(
      debt_tracking_mode: "summary", debt_summary_balance_cents: 0,
      debt_summary_minimum_payment_cents: 0,
      debt_summary_balance_known: true, debt_summary_minimum_payment_known: true
    )

    get "/api/v1/workspace", headers: auth_headers(user)

    assert_response :success
    setup_values = JSON.parse(response.body).fetch("workspace").fetch("setup_values")
    assert_equal 5_000, setup_values.fetch("emergency_fund")
    assert_equal 12_000, setup_values.fetch("other_assets")

    patch "/api/v1/workspace/setup",
          params: { workspace: setup_values },
          headers: auth_headers(user),
          as: :json

    assert_response :success
    household.reload
    assert_equal 1_200_000, household.accounts.find_by!(account_type: "other").balance_cents
    assert_equal 3_000_000, household.accounts.find_by!(account_type: "investment").balance_cents
    assert_equal 47_000, JSON.parse(response.body).fetch("wealth").fetch("summary").fetch("net_worth")
  end

  test "workspace setup rejects negative income values" do
    user = create_user(email: "negative-income@example.com")

    patch "/api/v1/workspace/setup",
          params: { workspace: { primary_income: -500 } },
          headers: auth_headers(user),
          as: :json

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_includes body.fetch("errors"), "Primary income must be a number with no more than two decimal places"
    assert_empty user.households.first.income_sources
  end

  test "workspace setup rejects blank household names" do
    user = create_user(email: "blank-name@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    household.update!(name: "Original Household")

    patch "/api/v1/workspace/setup",
          params: { workspace: { household_name: "" } },
          headers: auth_headers(user),
          as: :json

    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body).fetch("errors"), "Name can't be blank"
    assert_equal "Original Household", household.reload.name
  end

  test "workspace setup can clear the primary goal" do
    user = create_user(email: "clear-goal@example.com")

    patch "/api/v1/workspace/setup",
          params: { workspace: { primary_goal: "Leave my job safely" } },
          headers: auth_headers(user),
          as: :json
    patch "/api/v1/workspace/setup",
          params: { workspace: { primary_goal: "" } },
          headers: auth_headers(user),
          as: :json

    assert_response :success
    household = user.households.first
    assert_nil household.reload.primary_goal
    assert_empty household.goals.where(goal_type: "transition")
    assert_equal "", JSON.parse(response.body).fetch("workspace").fetch("setup_values").fetch("primary_goal")
  end

  test "workspace setup updates transition goal instead of duplicating it" do
    user = create_user(email: "goal@example.com")

    patch "/api/v1/workspace/setup",
          params: { workspace: { primary_goal: "Leave my job safely" } },
          headers: auth_headers(user),
          as: :json
    patch "/api/v1/workspace/setup",
          params: { workspace: { primary_goal: "Buy a rental property" } },
          headers: auth_headers(user),
          as: :json

    assert_response :success
    household = user.households.first
    transition_goals = household.goals.where(goal_type: "transition")
    assert_equal 1, transition_goals.count
    assert_equal "Buy a rental property", transition_goals.first.label
  end

  test "workspaces are isolated per user" do
    first_user = create_user(email: "first@example.com")
    second_user = create_user(email: "second@example.com")

    patch "/api/v1/workspace/setup",
          params: { workspace: { household_name: "First Household", primary_income: 5_000 } },
          headers: auth_headers(first_user),
          as: :json
    patch "/api/v1/workspace/setup",
          params: { workspace: { household_name: "Second Household", primary_income: 9_000 } },
          headers: auth_headers(second_user),
          as: :json

    get "/api/v1/workspace", headers: auth_headers(first_user)

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "First Household", body.fetch("profile").fetch("household").fetch("name")
    assert_equal 5_000, body.fetch("dashboard").fetch("summary").fetch("monthly_income")
  end

  test "wealth liquid net worth excludes long-term debt" do
    user = create_user(email: "liquid@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    household.accounts.create!(label: "Emergency fund", account_type: "emergency_fund", balance_cents: 10_000_000)
    household.accounts.create!(label: "Known other assets", account_type: "other", balance_cents: 0, balance_known: true)
    household.debts.create!(label: "Credit card debt", debt_type: "credit_card", balance_cents: 2_000_000)
    household.debts.create!(label: "Mortgage", debt_type: "mortgage", balance_cents: 50_000_000)

    get "/api/v1/workspace", headers: auth_headers(user)

    assert_response :success
    wealth = JSON.parse(response.body).fetch("wealth").fetch("summary")
    assert_equal(-420_000, wealth.fetch("net_worth"))
    assert_equal 80_000, wealth.fetch("liquid_net_worth")
    assert wealth.fetch("liquid_net_worth_available")

    household.household_profile.update!(
      debt_tracking_mode: "summary", debt_summary_balance_cents: 52_000_000,
      debt_summary_minimum_payment_cents: 0,
      debt_summary_balance_known: true, debt_summary_minimum_payment_known: true
    )

    get "/api/v1/workspace", headers: auth_headers(user)

    summary_wealth = response.parsed_body.fetch("wealth").fetch("summary")
    assert_equal(-420_000, summary_wealth.fetch("net_worth"))
    assert_nil summary_wealth.fetch("liquid_net_worth")
    refute summary_wealth.fetch("liquid_net_worth_available")
  end

  test "dashboard account rows use only the canonical debt portfolio" do
    user = create_user(email: "canonical-dashboard-debt@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    household.debts.create!(label: "Visa", debt_type: "credit_card", balance_cents: 2_000_00, minimum_payment_cents: 90_00)
    household.debts.create!(
      label: "Archived loan", debt_type: "personal_loan", balance_cents: 5_000_00,
      minimum_payment_cents: 200_00, active: false, archived_at: Time.current
    )
    household.household_profile.update!(
      debt_tracking_mode: "summary", debt_summary_balance_cents: 9_000_00,
      debt_summary_minimum_payment_cents: 375_00,
      debt_summary_balance_known: true, debt_summary_minimum_payment_known: true
    )

    get "/api/v1/workspace", headers: auth_headers(user)

    assert_response :success
    debt_rows = JSON.parse(response.body).dig("dashboard", "accounts").select { |row| row.fetch("type") == "debt" }
    assert_equal [ { "name" => "Household debt summary", "type" => "debt", "balance" => -9_000 } ], debt_rows
  end

  test "editing profile text preserves unknown summary debt values" do
    user = create_user(email: "profile-preserves-unknown-debt@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    profile = household.household_profile
    profile.update!(debt_tracking_mode: "summary", debt_summary_balance_known: false, debt_summary_minimum_payment_known: false)

    patch "/api/v1/workspace/setup",
      params: { workspace: { household_name: "Renamed household" } },
      headers: auth_headers(user),
      as: :json

    assert_response :success
    assert_equal "Renamed household", household.reload.name
    assert_not profile.reload.debt_summary_balance_known?
    assert_not profile.debt_summary_minimum_payment_known?
  end

  test "mia chat uses real workspace context and persists messages" do
    user = create_user(email: "mia@example.com")
    patch "/api/v1/workspace/setup",
          params: { workspace: { primary_income: 8_000, fixed_expenses: 4_000, emergency_fund: 8_000 } },
          headers: auth_headers(user),
          as: :json
    confirm_setup_for_test(user)

    post "/api/v1/mia/messages",
         params: { message: "Can I buy the purse?" },
         headers: auth_headers(user),
         as: :json

    assert_response :created
    content = JSON.parse(response.body).fetch("assistant_message").fetch("content")
    assert_includes content, "This purchase should wait"
    assert_includes content, "fund it from true surplus"
    refute_match(/guam|chamorro|chelu|lanya|island/i, content)

    get "/api/v1/mia/messages", headers: auth_headers(user)

    assert_response :success
    messages = JSON.parse(response.body).fetch("messages")
    assert_equal [ "user", "assistant" ], messages.map { |message| message.fetch("role") }
  end

  test "mia chat replays a completed request without duplicating messages" do
    user = create_user(email: "mia-idempotent-replay@example.com")
    request = { message: "Can I buy the purse?", request_id: "mia-request-replay-1" }

    assert_difference("ChatMessage.count" => 2, "MiaMessageRequest.count" => 1) do
      post "/api/v1/mia/messages", params: request, headers: auth_headers(user), as: :json
    end

    assert_response :created
    first_payload = JSON.parse(response.body)

    assert_no_difference([ "ChatMessage.count", "MiaMessageRequest.count", "MiaActionDraft.count", "TransactionDraft.count" ]) do
      post "/api/v1/mia/messages", params: request, headers: auth_headers(user), as: :json
    end

    assert_response :created
    assert_equal first_payload, JSON.parse(response.body)
  end

  test "mia chat rejects reuse of a request ID for different content" do
    user = create_user(email: "mia-idempotent-conflict@example.com")
    post "/api/v1/mia/messages",
         params: { message: "Can I buy the purse?", request_id: "mia-request-conflict-1" },
         headers: auth_headers(user),
         as: :json
    assert_response :created

    assert_no_difference([ "ChatMessage.count", "MiaMessageRequest.count" ]) do
      post "/api/v1/mia/messages",
           params: { message: "Set Dining Out to $900", request_id: "mia-request-conflict-1" },
           headers: auth_headers(user),
           as: :json
    end

    assert_response :conflict
    body = JSON.parse(response.body)
    assert_equal "mia_request_conflict", body.fetch("code")
    assert_includes body.fetch("error"), "different content"
  end

  test "mia request replay is bound to the participant cohort release" do
    user = create_user(email: "mia-release-idempotency@example.com")
    owner = User.create!(
      clerk_id: "clerk_#{SecureRandom.hex(6)}",
      email: "mia-release-idempotency-coach@example.com",
      role: "coach",
      invitation_status: "accepted"
    )
    cohort = Cohort.create!(name: "Replay release #{SecureRandom.hex(4)}", status: "active", created_by_user: owner)
    cohort.cohort_memberships.create!(user: user, role: "participant")
    candidate = CohortReleases::CandidateBuilder.new(cohort: cohort, strict: false).call
    sealer = CohortReleases::Sealer.new(cohort: cohort, actor: nil, publication_source: "system")
    baseline = sealer.call!(request_key: "replay-baseline", expected_bundle_digest: candidate.bundle_digest)
    target = sealer.call!(request_key: "replay-target", expected_bundle_digest: candidate.bundle_digest)
    cohort.update!(active_cohort_release: baseline)
    request = { message: "How much is safe to spend?", request_id: "release-bound-request" }

    post "/api/v1/mia/messages", params: request, headers: auth_headers(user), as: :json
    assert_response :created

    cohort.update!(active_cohort_release: target)
    post "/api/v1/mia/messages", params: request, headers: auth_headers(user), as: :json

    assert_response :conflict
    assert_equal "mia_request_conflict", response.parsed_body.fetch("code")
  end

  test "mia request replay is bound to a legacy cohort even without an active release" do
    user = create_user(email: "mia-legacy-cohort-idempotency@example.com")
    owner = create_user(email: "mia-legacy-cohort-coach@example.com", role: "coach")
    first = Cohort.create!(name: "Legacy replay first #{SecureRandom.hex(4)}", status: "active", created_by_user: owner)
    second = Cohort.create!(name: "Legacy replay second #{SecureRandom.hex(4)}", status: "active", created_by_user: owner)
    first.cohort_memberships.create!(user: user, role: "participant")
    second.cohort_memberships.create!(user: user, role: "participant")
    request = { message: "How much is safe to spend?", request_id: "legacy-cohort-bound-request" }

    post "/api/v1/mia/messages", params: request,
      headers: auth_headers(user).merge("X-Cohort-Id" => first.id.to_s), as: :json
    assert_response :created

    post "/api/v1/mia/messages", params: request,
      headers: auth_headers(user).merge("X-Cohort-Id" => second.id.to_s), as: :json

    assert_response :conflict
    assert_equal "mia_request_conflict", response.parsed_body.fetch("code")
  end

  test "mia transaction idempotency keys are scoped to the current user and chat session" do
    controller = Api::V1::MiaMessagesController.new
    controller.request = ActionDispatch::TestRequest.create
    controller.instance_variable_set(:@active_mia_message_request, Struct.new(:request_key).new("shared-request"))
    user_id = 101
    session_id = 201
    controller.define_singleton_method(:current_user) { Struct.new(:id).new(user_id) }
    controller.define_singleton_method(:current_chat_session) { Struct.new(:id).new(session_id) }

    first = controller.send(:mia_transaction_idempotency_key, "create")
    user_id = 102
    second_user = controller.send(:mia_transaction_idempotency_key, "create")
    user_id = 101
    session_id = 202
    second_session = controller.send(:mia_transaction_idempotency_key, "create")

    assert_equal "mia-transaction:101:201:shared-request:create", first
    refute_equal first, second_user
    refute_equal first, second_session
  end

  test "mia chat reports an in-flight duplicate as retryable processing" do
    user = create_user(email: "mia-idempotent-processing@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    session = household.chat_sessions.create!(user: user, title: "Ask Mia")
    content = "Can I buy the purse?"
    fingerprint = Digest::SHA256.hexdigest(
      {
        message: content,
        year: Date.current.year,
        month: Date.current.month,
        document_import_ids: []
      }.to_json
    )
    session.mia_message_requests.create!(
      request_key: "mia-request-processing-1",
      request_fingerprint: fingerprint
    )

    assert_no_difference("ChatMessage.count") do
      post "/api/v1/mia/messages",
           params: { message: content, request_id: "mia-request-processing-1" },
           headers: auth_headers(user),
           as: :json
    end

    assert_response :accepted
    body = JSON.parse(response.body)
    assert_equal "mia_request_processing", body.fetch("code")
    assert_equal "processing", body.fetch("status")
    assert_equal "1", response.headers.fetch("Retry-After")
  end

  test "mia chat turns a stale in-flight duplicate into a terminal safe failure" do
    user = create_user(email: "mia-idempotent-stale@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    session = household.chat_sessions.create!(user: user, title: "Ask Mia")
    content = "Can I buy the purse?"
    fingerprint = Digest::SHA256.hexdigest(
      { message: content, year: Date.current.year, month: Date.current.month, document_import_ids: [] }.to_json
    )
    request = session.mia_message_requests.create!(request_key: "mia-request-stale-1", request_fingerprint: fingerprint)
    request.update_column(:updated_at, 4.minutes.ago)

    assert_no_difference("ChatMessage.count") do
      post "/api/v1/mia/messages",
           params: { message: content, request_id: "mia-request-stale-1" },
           headers: auth_headers(user),
           as: :json
    end

    assert_response :service_unavailable
    assert_equal "mia_request_failed", JSON.parse(response.body).fetch("code")
    assert request.reload.failed?
  end

  test "mia chat records an unexpected post-reservation failure as terminal and replays it safely" do
    user = create_user(email: "mia-idempotent-exception@example.com")
    request = { message: "Can I buy the purse?", request_id: "mia-request-exception-1" }
    replacement = ->(*) { raise "simulated post-reservation failure" }

    assert_raises(RuntimeError) do
      with_singleton_stub(HouseholdFinance::ConversationTranscriptBuilder, :new, replacement) do
        post "/api/v1/mia/messages", params: request, headers: auth_headers(user), as: :json
      end
    end

    failed = MiaMessageRequest.find_by!(request_key: "mia-request-exception-1")
    assert failed.failed?
    assert_no_difference([ "ChatMessage.count", "MiaMessageRequest.count" ]) do
      post "/api/v1/mia/messages", params: request, headers: auth_headers(user), as: :json
    end
    assert_response :service_unavailable
    assert_equal "mia_request_failed", JSON.parse(response.body).fetch("code")
  end

  test "mia chat validates request IDs before any financial work" do
    user = create_user(email: "mia-idempotent-invalid@example.com")

    assert_no_difference([ "ChatMessage.count", "MiaMessageRequest.count" ]) do
      post "/api/v1/mia/messages",
           params: { message: "Can I buy the purse?", request_id: "not a safe key" },
           headers: auth_headers(user),
           as: :json
    end

    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body).fetch("errors"), "Mia request ID is invalid"
  end

  test "mia intent provider transcript excludes another participant's legacy phrase" do
    coach = create_user(email: "phrase-audience-coach@example.com", role: "coach")
    user = create_user(email: "phrase-audience-current@example.com")
    source_participant = create_user(email: "phrase-audience-source@example.com")
    config = persona_configuration(assistant_name: "Coach Lila", coach_name: "Coach June")
    config["phrases"] = [
      persona_phrase_artifact(
        { "text" => "Steady steps", "meaning" => "The coach's shared reminder." },
        source_user_id: coach.id
      ),
      persona_phrase_artifact(
        { "text" => "My grocery check", "meaning" => "The current participant's wording." },
        source_user_id: user.id,
        provenance: "participant_supplied"
      ),
      persona_phrase_artifact(
        { "text" => "Auntie's grocery rule", "meaning" => "Another participant's private wording." },
        source_user_id: source_participant.id,
        provenance: "participant_supplied"
      )
    ]
    persona = CoachPersona.create!(
      name: "Coach Lila",
      description: "Intent transcript audience fixture.",
      draft_config: config,
      created_by_user: coach
    )
    version = publish_persona(persona, actor: coach)
    cohort = Cohort.create!(name: "Intent transcript cohort", status: "active", created_by_user: coach)
    cohort.cohort_memberships.create!(user: user, role: "participant")
    cohort.cohort_memberships.create!(user: source_participant, role: "participant")
    CohortPersonaAssignment.create!(cohort: cohort, coach_persona: persona, assigned_by_user: coach)
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    session = household.chat_sessions.create!(user: user, title: "Ask Mia")
    session.chat_messages.create!(
      role: "assistant",
      content: "Steady steps. My grocery check. Auntie's grocery rule. Review the list.",
      coach_persona_version: version,
      assistant_author: "Coach Lila",
      cohort: cohort
    )
    captured_contexts = []
    fake_resolver = lambda do |**kwargs|
      captured_contexts << kwargs.fetch(:context)
      Object.new.tap { |object| object.define_singleton_method(:call) { nil } }
    end

    with_singleton_stub(HouseholdFinance::MiaIntentResolver, :new, fake_resolver) do
      post "/api/v1/mia/messages",
           params: { message: "Please explain my budget options." },
           headers: auth_headers(user),
           as: :json
    end

    assert_response :created
    context = captured_contexts.sole
    recent_content = context.dig(:conversation, :recent_messages).pluck(:content).join(" ")
    assert_includes recent_content, "Steady steps"
    assert_includes recent_content, "My grocery check"
    refute_includes recent_content, "Auntie's grocery rule"

    provider_payload = HouseholdFinance::MiaIntentResolver.new(
      user_message: "Please explain my budget options.",
      context: context
    ).send(:payload).to_json
    assert_includes provider_payload, "Steady steps"
    assert_includes provider_payload, "My grocery check"
    refute_includes provider_payload, "Auntie's grocery rule"
  end

  test "mia chat routes deterministic coaching packets through Mia narrator" do
    user = create_user(email: "mia-narrator@example.com")
    patch "/api/v1/workspace/setup",
          params: { workspace: { primary_income: 8_000, fixed_expenses: 4_000, emergency_fund: 8_000 } },
          headers: auth_headers(user),
          as: :json
    confirm_setup_for_test(user)
    packets = []
    fake_narrator = ->(**kwargs) {
      packets << kwargs.fetch(:answer_packet)
      Object.new.tap { |object| object.define_singleton_method(:call) { "Narrated in Mia voice from Rails facts." } }
    }

    with_singleton_stub(HouseholdFinance::MiaNarrator, :new, fake_narrator) do
      post "/api/v1/mia/messages",
           params: { message: "Can I buy concert tickets?" },
           headers: auth_headers(user),
           as: :json
    end

    assert_response :created
    assert_equal "Narrated in Mia voice from Rails facts.", JSON.parse(response.body).fetch("assistant_message").fetch("content")
    assert_equal "coaching", packets.first.fetch(:kind)
    assert_equal "no_write", packets.first.fetch(:write_state)
    assert_includes packets.first.fetch(:fallback_response), "safe-to-spend"
  end

  test "mia chat preserves deterministic compound decision math when intent labels it a budget question" do
    user = create_user(email: "mia-compound-routing@example.com")
    patch "/api/v1/workspace/setup",
          params: { workspace: { primary_income: 8_000, fixed_expenses: 4_000, emergency_fund: 8_000 } },
          headers: auth_headers(user),
          as: :json
    confirm_setup_for_test(user)
    intent_result = HouseholdFinance::MiaIntentResolver::Result.new(
      intent: "budget_question",
      confidence: 0.99,
      continuation: false,
      resolved_message: "Can I take a $900 trip and make a $750 extra debt payment this month? Show both against the plan.",
      needs_clarification: false,
      clarification: "",
      topic: { type: "budget_question", title: "Trip and debt decision", subject: "Trip and debt" },
      action: { type: "none" },
      source: "model"
    )
    fake_resolver = ->(**_kwargs) { Object.new.tap { |object| object.define_singleton_method(:call) { intent_result } } }

    with_singleton_stub(HouseholdFinance::MiaIntentResolver, :new, fake_resolver) do
      post "/api/v1/mia/messages",
           params: { message: "Can I take a $900 trip and make a $750 extra debt payment this month? Show both against the plan." },
           headers: auth_headers(user),
           as: :json
    end

    assert_response :created
    content = JSON.parse(response.body).fetch("assistant_message").fetch("content")
    assert_includes content, "proposed purchase is $900"
    assert_includes content, "extra debt payment is $750"
    assert_includes content, "together they total $1,650"
    assert_includes content, "not a second safe-to-spend allowance"
  end

  test "mia chat summarizes processed receipt drafts before replying" do
    user = create_user(email: "mia-receipt-sync@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    document_import = household.financial_document_imports.create!(
      uploaded_by_user: user,
      document_kind: "receipt",
      status: "needs_review",
      filename: "resend-receipt.png",
      content_type: "image/png",
      byte_size: 128,
      s3_key: "household-cfo/test/resend-receipt.png"
    )
    category = household.budget_categories.create!(name: "Software", stack_key: "discretionary", sort_order: 1)
    document_import.transaction_drafts.create!(
      household: household,
      occurred_on: Date.new(2026, 7, 3),
      merchant: "Resend",
      total_amount_cents: 20_00,
      budget_category: category,
      source_type: "receipt",
      status: "pending",
      raw_input: "Resend receipt"
    )

    post "/api/v1/mia/messages",
         params: { message: "Check this receipt", document_import_ids: [ document_import.id ] },
         headers: auth_headers(user),
         as: :json

    assert_response :created
    body = JSON.parse(response.body)
    assistant_content = body.fetch("assistant_message").fetch("content")
    assert_includes assistant_content, "I found Resend for $20"
    assert_equal "needs_review", document_import.reload.status
    assert_equal "Resend", document_import.transaction_drafts.first.merchant
  end

  test "mia chat summarizes a completed statement with its full pending review count" do
    user = create_user(email: "mia-statement-sync@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    document_import = household.financial_document_imports.create!(
      uploaded_by_user: user,
      document_kind: "statement",
      status: "needs_review",
      filename: "statement.pdf",
      content_type: "application/pdf",
      byte_size: 128,
      s3_key: "household-cfo/test/statement.pdf"
    )
    3.times do |index|
      document_import.transaction_drafts.create!(
        household: household,
        occurred_on: Date.new(2026, 7, index + 1),
        merchant: "Statement merchant #{index}",
        total_amount_cents: (index + 1) * 100,
        source_type: "statement",
        status: "pending",
        raw_input: "Statement row"
      )
    end

    post "/api/v1/mia/messages",
         params: { message: "Review every transaction", document_import_ids: [ document_import.id ] },
         headers: auth_headers(user),
         as: :json

    assert_response :created
    assistant_content = JSON.parse(response.body).dig("assistant_message", "content")
    assert_includes assistant_content, "Finished reading the statement upload"
    assert_includes assistant_content, "routed the upload to pending transaction review"
    assert_includes assistant_content, "3 pending transaction reviews"
    assert_includes assistant_content, "Jul 1, 2026 through Jul 3, 2026"
  end

  test "mia chat surfaces a document routing conflict without changing household numbers" do
    user = create_user(email: "mia-routing-conflict@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    document_import = household.financial_document_imports.create!(
      uploaded_by_user: user,
      document_kind: "pay_stub",
      status: "needs_review",
      filename: "income.png",
      content_type: "image/png",
      byte_size: 128,
      s3_key: "household-cfo/test/income.png",
      metadata: {
        "routing_detected_kind" => "statement",
        "routing_resolved_kind" => "pay_stub",
        "routing_requires_confirmation" => true,
        "routing_destination" => "household_setup_review"
      }
    )

    assert_no_difference("IncomeSource.count") do
      post "/api/v1/mia/messages",
           params: { message: "Use this pay stub to help update my income", document_import_ids: [ document_import.id ] },
           headers: auth_headers(user),
           as: :json
    end

    assert_response :created
    assistant_content = JSON.parse(response.body).dig("assistant_message", "content")
    assert_includes assistant_content, "You described this as pay stub, but I detected statement"
    assert_includes assistant_content, "flagged the routing difference for review"
    assert_includes assistant_content, "no household numbers changed"
  end

  test "mia chat persists attached document imports with a single contextual reply" do
    user = create_user(email: "mia-attachments@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    document_import = household.financial_document_imports.create!(
      uploaded_by_user: user,
      document_kind: "receipt",
      status: "needs_review",
      filename: "receipt.png",
      content_type: "image/png",
      byte_size: 128,
      s3_key: "household-cfo/test/receipt.png"
    )
    category = household.budget_categories.create!(name: "Software", stack_key: "discretionary", sort_order: 1)
    document_import.transaction_drafts.create!(
      household: household,
      occurred_on: Date.new(2026, 7, 3),
      merchant: "Resend",
      total_amount_cents: 20_00,
      budget_category: category,
      source_type: "receipt",
      status: "pending",
      raw_input: "Resend receipt"
    )

    post "/api/v1/mia/messages",
         params: { message: "Please read this receipt", document_import_ids: [ document_import.id ] },
         headers: auth_headers(user),
         as: :json

    assert_response :created
    body = JSON.parse(response.body)
    assert_nil body.fetch("transaction_draft")
    assistant_content = body.fetch("assistant_message").fetch("content")
    assert_includes assistant_content, "routed it to pending transaction review"
    assert_not_includes assistant_content, "I used your note as context"
    assert_includes assistant_content, "I found Resend for $20"
    attachment = body.fetch("user_message").fetch("attachments").first
    assert_equal document_import.id, attachment.fetch("document_import_id")
    assert_equal "receipt.png", attachment.fetch("filename")
    assert_equal "needs_review", attachment.fetch("status")
    operation = household.household_audit_events.find_by!(event_type: "mia.request.completed")
    assert_equal 1, operation.metadata.fetch("attachment_count")
    assert_operator operation.metadata.fetch("assistant_characters"), :>, 0

    get "/api/v1/mia/messages", headers: auth_headers(user)

    assert_response :success
    user_message = JSON.parse(response.body).fetch("messages").find { |message| message.fetch("role") == "user" }
    assert_equal document_import.id, user_message.fetch("attachments").first.fetch("document_import_id")
  end

  test "an unrelated attachment question leaves a validated clarification topic unchanged" do
    user = create_user(email: "mia-attachment-preserves-clarification@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    topic = {
      schema_version: 2,
      id: SecureRandom.uuid,
      type: "budget_edit",
      title: "Fixed essentials edit",
      subject: "Fixed essentials",
      status: "needs_clarification",
      latest_user_context: "Set Fixed essentials to $3,000.",
      action: { type: "set_allocation", category_id: 42, category_name: "Fixed essentials", amount: "3000", months: [], year: Date.current.year }
    }
    session = household.chat_sessions.create!(user: user, title: "Ask Mia", active_topic: topic, open_topics: [ topic ])
    document_import = household.financial_document_imports.create!(
      uploaded_by_user: user,
      document_kind: "receipt",
      status: "needs_review",
      filename: "unrelated-receipt.png",
      content_type: "image/png",
      byte_size: 128,
      s3_key: "household-cfo/test/unrelated-receipt.png"
    )
    document_import.transaction_drafts.create!(
      household: household,
      occurred_on: Date.current,
      merchant: "Pay-Less",
      total_amount_cents: 42_00,
      source_type: "receipt",
      status: "pending",
      raw_input: "receipt row"
    )
    intent_result = HouseholdFinance::MiaIntentResolver::Result.new(
      intent: "general",
      confidence: 0.99,
      continuation: false,
      resolved_message: "What is the total in this receipt?",
      needs_clarification: false,
      clarification: "",
      topic: { type: "", title: "", subject: "" },
      action: { type: "none" },
      read_only_plan: {},
      source: "model"
    )
    fake_resolver = ->(**_kwargs) { Object.new.tap { |object| object.define_singleton_method(:call) { intent_result } } }

    with_singleton_stub(HouseholdFinance::MiaIntentResolver, :new, fake_resolver) do
      post "/api/v1/mia/messages",
           params: { message: "What is the total in this receipt?", document_import_ids: [ document_import.id ] },
           headers: auth_headers(user),
           as: :json
    end

    assert_response :created
    body = JSON.parse(response.body)
    assert_includes body.dig("assistant_message", "content"), "$42"
    assert_nil body.fetch("budget")
    assert_equal topic.deep_stringify_keys, session.reload.active_topic
    assert_equal "Set Fixed essentials to $3,000.", session.active_topic.fetch("latest_user_context")

    post "/api/v1/mia/messages",
         params: { message: "What is the largest transaction in that upload?" },
         headers: auth_headers(user),
         as: :json

    assert_response :created
    assert_includes response.parsed_body.dig("assistant_message", "content"), "Using your prior upload"
    assert_includes response.parsed_body.dig("assistant_message", "content"), "Pay-Less"
    assert_equal topic.deep_stringify_keys, session.reload.active_topic
  end

  test "an attachment turn can complete a validated structured clarification" do
    user = create_user(email: "mia-attachment-completes-clarification@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    manager = HouseholdFinance::AnnualBudgetManager.new(household, year: Date.current.year)
    category = manager.create_category!(name: "Fixed essentials", stack_key: "non_discretionary", monthly_amount: 4_000)
    topic = {
      schema_version: 2,
      id: SecureRandom.uuid,
      type: "budget_edit",
      title: "Fixed essentials edit",
      subject: "Fixed essentials",
      status: "needs_clarification",
      latest_user_context: "Set Fixed essentials to $3,000.",
      action: { type: "set_allocation", category_id: category.id, category_name: category.name, amount: "3000", months: [], year: Date.current.year }
    }
    session = household.chat_sessions.create!(user: user, title: "Ask Mia", active_topic: topic, open_topics: [ topic ])
    document_import = household.financial_document_imports.create!(
      uploaded_by_user: user,
      document_kind: "receipt",
      status: "needs_review",
      filename: "clarification-receipt.png",
      content_type: "image/png",
      byte_size: 128,
      s3_key: "household-cfo/test/clarification-receipt.png"
    )
    document_import.transaction_drafts.create!(
      household: household,
      occurred_on: Date.current,
      merchant: "Costco",
      total_amount_cents: 55_00,
      source_type: "receipt",
      status: "pending",
      raw_input: "receipt row"
    )
    intent_result = HouseholdFinance::MiaIntentResolver::Result.new(
      intent: "budget_action",
      confidence: 0.99,
      continuation: true,
      resolved_message: "Set Fixed essentials to $3,000 for August #{Date.current.year}",
      needs_clarification: false,
      clarification: "",
      topic: { type: "budget_edit", title: "Fixed essentials edit", subject: "Fixed essentials" },
      action: { type: "set_allocation", category_id: category.id, category_name: category.name, amount: "3000", months: [ 8 ], year: Date.current.year },
      read_only_plan: {},
      source: "model"
    )
    fake_resolver = ->(**_kwargs) { Object.new.tap { |object| object.define_singleton_method(:call) { intent_result } } }

    assert_difference("MiaActionDraft.count", 1) do
      with_singleton_stub(HouseholdFinance::MiaIntentResolver, :new, fake_resolver) do
        post "/api/v1/mia/messages",
             params: { message: "August only.", document_import_ids: [ document_import.id ] },
             headers: auth_headers(user),
             as: :json
      end
    end

    assert_response :created
    body = JSON.parse(response.body)
    assert_includes body.dig("assistant_message", "content"), "Costco"
    assert body.fetch("mia_action_draft")
    assert body.fetch("budget")
    assert_equal "pending_review", session.reload.active_topic.fetch("status")
    assert_equal [ 8 ], session.active_topic.dig("action", "months")
    assert_equal "August only.", session.active_topic.fetch("latest_user_context")
  end

  test "a combined attachment question and supported action returns both evidence and a review draft" do
    user = create_user(email: "mia-attachment-combined-action@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    manager = HouseholdFinance::AnnualBudgetManager.new(household, year: Date.current.year)
    category = manager.create_category!(name: "Groceries", stack_key: "discretionary", monthly_amount: 700)
    document_import = household.financial_document_imports.create!(
      uploaded_by_user: user,
      document_kind: "receipt",
      status: "needs_review",
      filename: "combined-receipt.png",
      content_type: "image/png",
      byte_size: 128,
      s3_key: "household-cfo/test/combined-receipt.png"
    )
    document_import.transaction_drafts.create!(
      household: household,
      occurred_on: Date.current,
      merchant: "Pay-Less",
      total_amount_cents: 87_45,
      source_type: "receipt",
      status: "pending",
      raw_input: "receipt row"
    )
    message = "Which merchant is on this receipt and what is the total? Also set Groceries to $900 for August."
    intent_result = HouseholdFinance::MiaIntentResolver::Result.new(
      intent: "budget_action",
      confidence: 0.99,
      continuation: false,
      resolved_message: "Set Groceries to $900 for August #{Date.current.year}",
      needs_clarification: false,
      clarification: "",
      topic: { type: "budget_edit", title: "August Groceries edit", subject: "Groceries" },
      action: { type: "set_allocation", category_id: category.id, category_name: category.name, amount: "900", months: [ 8 ], year: Date.current.year },
      read_only_plan: {},
      source: "model"
    )
    fake_resolver = ->(**_kwargs) { Object.new.tap { |object| object.define_singleton_method(:call) { intent_result } } }

    assert_difference("MiaActionDraft.count", 1) do
      with_singleton_stub(HouseholdFinance::MiaIntentResolver, :new, fake_resolver) do
        post "/api/v1/mia/messages",
             params: { message: message, document_import_ids: [ document_import.id ] },
             headers: auth_headers(user),
             as: :json
      end
    end

    assert_response :created
    body = JSON.parse(response.body)
    assistant_content = body.dig("assistant_message", "content")
    assert_includes assistant_content, "$87.45"
    assert_includes assistant_content, "Pay-Less"
    assert body.fetch("mia_action_draft")
    assert body.fetch("budget")
    draft = household.mia_action_drafts.pending.last
    change = draft.mia_action_items.first.payload.fetch("changes").sole
    assert_equal 8, change.fetch("month")
    assert_equal 90_000, change.fetch("after_cents")
    assert_equal document_import.id, body.dig("user_message", "attachments", 0, "document_import_id")
  end

  test "a failed attached action draft rolls back newly prepared plan records" do
    user = create_user(email: "mia-attachment-action-persistence-failure@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    category = household.budget_categories.create!(name: "Groceries", stack_key: "discretionary", sort_order: 1)
    document_import = household.financial_document_imports.create!(
      uploaded_by_user: user,
      document_kind: "receipt",
      status: "needs_review",
      filename: "failed-action-receipt.png",
      content_type: "image/png",
      byte_size: 128,
      s3_key: "household-cfo/test/failed-action-receipt.png"
    )
    document_import.transaction_drafts.create!(
      household: household,
      occurred_on: Date.current,
      merchant: "Pay-Less",
      total_amount_cents: 87_45,
      source_type: "receipt",
      status: "pending",
      raw_input: "receipt row"
    )
    message = "What is the receipt total? Also set Groceries to $900 for August."
    intent_result = HouseholdFinance::MiaIntentResolver::Result.new(
      intent: "budget_action",
      confidence: 0.99,
      continuation: false,
      resolved_message: "Set Groceries to $900 for August #{Date.current.year}",
      needs_clarification: false,
      clarification: "",
      topic: { type: "budget_edit", title: "August Groceries edit", subject: "Groceries" },
      action: { type: "set_allocation", category_id: category.id, category_name: category.name, amount: "900", months: [ 8 ], year: Date.current.year },
      read_only_plan: {},
      source: "model"
    )
    fake_resolver = ->(**_kwargs) { Object.new.tap { |object| object.define_singleton_method(:call) { intent_result } } }
    coach = persona_user(email: "attachment-citation-coach@example.com")
    content_item = approved_content_item(owner: coach, title: "Attached action context", content: "Offer one clear review step.")
    content_pack = published_content_pack(owner: coach, items: [ content_item ])
    forced_citation = {
      item_version: content_item.current_approved_version,
      pack_version: content_pack.current_published_version,
      rank: 1,
      reason: "Context supplied for: review"
    }
    original_create_draft = HouseholdFinance::MiaActionDraftBuilder::Proposal.instance_method(:create_draft!)
    original_assistant_content = Api::V1::MiaMessagesController.instance_method(:assistant_content_for)

    begin
      HouseholdFinance::MiaActionDraftBuilder::Proposal.define_method(:create_draft!) do |**|
        raise RuntimeError, "simulated attached draft persistence failure"
      end
      Api::V1::MiaMessagesController.define_method(:assistant_content_for) do |*, **|
        @used_coach_content = [ forced_citation ]
        "I prepared the requested budget update for review."
      end

      assert_no_difference([ "BudgetYear.count", "BudgetPeriod.count", "BudgetAllocation.count", "MiaActionDraft.count" ]) do
        with_singleton_stub(HouseholdFinance::MiaIntentResolver, :new, fake_resolver) do
          post "/api/v1/mia/messages",
               params: { message: message, document_import_ids: [ document_import.id ] },
               headers: auth_headers(user),
               as: :json
        end
      end
      assert_equal 0, household.budget_years.count
      assert_equal 0, BudgetPeriod.where(budget_year_id: household.budget_years.select(:id)).count
      assert_equal 0, BudgetAllocation.where(budget_period_id: BudgetPeriod.where(budget_year_id: household.budget_years.select(:id))).count

      HouseholdFinance::AnnualBudgetManager.new(household, year: Date.current.year).ensure_plan!
      budget_year_ids = household.budget_years.order(:id).pluck(:id)
      budget_period_ids = BudgetPeriod.where(budget_year_id: budget_year_ids).order(:id).pluck(:id)
      budget_allocation_ids = BudgetAllocation.where(budget_period_id: budget_period_ids).order(:id).pluck(:id)
      assert_no_difference([ "BudgetYear.count", "BudgetPeriod.count", "BudgetAllocation.count", "MiaActionDraft.count" ]) do
        with_singleton_stub(HouseholdFinance::MiaIntentResolver, :new, fake_resolver) do
          post "/api/v1/mia/messages",
               params: { message: message, document_import_ids: [ document_import.id ] },
               headers: auth_headers(user),
               as: :json
        end
      end
      assert_equal budget_year_ids, household.budget_years.order(:id).pluck(:id)
      assert_equal budget_period_ids, BudgetPeriod.where(budget_year_id: budget_year_ids).order(:id).pluck(:id)
      assert_equal budget_allocation_ids, BudgetAllocation.where(budget_period_id: budget_period_ids).order(:id).pluck(:id)
    ensure
      HouseholdFinance::MiaActionDraftBuilder::Proposal.define_method(:create_draft!, original_create_draft)
      Api::V1::MiaMessagesController.define_method(:assistant_content_for, original_assistant_content)
    end

    assert_response :created
    body = JSON.parse(response.body)
    assert_nil body.fetch("mia_action_draft")
    assert_nil body.fetch("budget")
    assert_includes body.dig("assistant_message", "content"), "$87.45"
    assert_includes body.dig("assistant_message", "content"), "could not prepare the review card"
    assert_empty body.dig("assistant_message", "citations")
    assert_empty CoachContentCitation.where(chat_message_id: body.dig("assistant_message", "id"))
  end

  test "a combined attachment question and unsupported action returns evidence and an explicit boundary" do
    user = create_user(email: "mia-attachment-combined-boundary@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    document_import = household.financial_document_imports.create!(
      uploaded_by_user: user,
      document_kind: "receipt",
      status: "needs_review",
      filename: "combined-boundary-receipt.png",
      content_type: "image/png",
      byte_size: 128,
      s3_key: "household-cfo/test/combined-boundary-receipt.png"
    )
    transaction_draft = document_import.transaction_drafts.create!(
      household: household,
      occurred_on: Date.current,
      merchant: "Costco",
      total_amount_cents: 64_20,
      source_type: "receipt",
      status: "pending",
      raw_input: "receipt row"
    )
    intent_result = HouseholdFinance::MiaIntentResolver::Result.new(
      intent: "transaction_draft_action",
      confidence: 0.99,
      continuation: false,
      resolved_message: "Change the pending Costco transaction to $60",
      needs_clarification: false,
      clarification: "",
      topic: { type: "transaction_draft", title: "Costco draft", subject: "Costco" },
      action: { type: "update_transaction_draft", transaction_draft_id: transaction_draft.id, amount: "60" },
      read_only_plan: {},
      source: "model"
    )
    fake_resolver = ->(**_kwargs) { Object.new.tap { |object| object.define_singleton_method(:call) { intent_result } } }

    assert_no_difference([ "MiaActionDraft.count", "HouseholdTransaction.count" ]) do
      with_singleton_stub(HouseholdFinance::MiaIntentResolver, :new, fake_resolver) do
        post "/api/v1/mia/messages",
             params: {
               message: "What is the receipt total? Also change the pending transaction to $60.",
               document_import_ids: [ document_import.id ]
             },
             headers: auth_headers(user),
             as: :json
      end
    end

    assert_response :created
    body = JSON.parse(response.body)
    assert_includes body.dig("assistant_message", "content"), "$64.20"
    assert_includes body.dig("assistant_message", "content"), "could not safely prepare"
    assert_nil body.fetch("mia_action_draft")
    assert_nil body.fetch("budget")
    assert_equal "pending", transaction_draft.reload.status
    assert_equal 64_20, transaction_draft.total_amount_cents
  end

  test "an unresolved attached account action preserves evidence and asks for the action separately" do
    assert_unresolved_attached_account_action(needs_clarification: false)
  end

  test "an attached account clarification preserves evidence and asks for the action separately" do
    assert_unresolved_attached_account_action(needs_clarification: true)
  end

  test "a sentence-separated attached account action preserves evidence and asks for the action separately" do
    assert_unresolved_attached_account_action(
      needs_clarification: false,
      message: "Review this statement. Link my bank account",
      expected_evidence_prompt: "Review this statement"
    )
  end

  test "semicolon and newline attached account clarifications preserve only the evidence request" do
    [
      "Review this statement; Update my checking account",
      "Review this statement\nUpdate my checking account"
    ].each do |message|
      assert_unresolved_attached_account_action(
        needs_clarification: true,
        message: message,
        expected_evidence_prompt: "Review this statement"
      )
    end
  end

  test "attachment action detection covers account and bank lifecycle requests" do
    controller = Api::V1::MiaMessagesController.new

    [
      "Review this statement and update my checking account",
      "Review this statement and link my bank account",
      "Review this statement and unlink this bank",
      "Review this statement and reconcile this asset",
      "Review this statement. Link my bank account",
      "Review this statement; Update my checking account",
      "Review this statement\nUpdate my checking account"
    ].each do |message|
      assert controller.send(:attachment_action_request?, message), "did not detect #{message.inspect}"
      refute controller.send(:pure_attachment_review_request?, message), "incorrectly treated #{message.inspect} as evidence-only"
    end
    [
      "Use this statement to update my budget",
      "Use this statement to set up my budget"
    ].each do |message|
      assert controller.send(:attachment_action_request?, message), "did not detect #{message.inspect}"
      refute controller.send(:pure_attachment_review_request?, message), "incorrectly treated #{message.inspect} as evidence-only"
    end
    assert controller.send(:pure_attachment_review_request?, "Review this bank statement")
    refute controller.send(:attachment_action_request?, "Review this bank statement")
  end

  test "attachment action detection covers polite imperatives and named category amounts" do
    controller = Api::V1::MiaMessagesController.new

    [
      "Review this statement and can you please update my budget",
      "Review this statement. Would you please update my bank account?",
      "Review this statement. I want you to update my budget",
      "Review this statement. I need you to set up my household",
      "Review this statement and set Groceries to $900"
    ].each do |message|
      assert controller.send(:attachment_action_request?, message), "did not detect #{message.inspect}"
      refute controller.send(:pure_attachment_review_request?, message), "incorrectly treated #{message.inspect} as evidence-only"
      assert_equal "Review this statement", controller.send(:attached_document_evidence_prompt, message, nil)
    end
  end

  test "attachment action detection excludes informational frames" do
    controller = Api::V1::MiaMessagesController.new

    [
      "Review this statement. Could you update me on which spending category increased?",
      "Review this statement. Can you increase my understanding of this budget?",
      "Review this statement. Tell me what category increased.",
      "Review this statement. Explain why my spending increased.",
      "Review this statement and add up my spending"
    ].each do |message|
      assert controller.send(:pure_attachment_review_request?, message), "did not keep #{message.inspect} evidence-only"
      refute controller.send(:attachment_action_request?, message), "incorrectly detected a household mutation in #{message.inspect}"
      assert_equal message, controller.send(:attached_document_evidence_prompt, message, nil)
    end
  end

  test "unresolved attached polite and named amount commands fail closed after preserving evidence" do
    cases = [
      [ "Review this statement and can you please update my budget", nil ],
      [ "Review this statement. Would you please update my bank account?", :action_none ],
      [ "Review this statement. I want you to update my budget", nil ],
      [ "Review this statement. I need you to set up my household", :action_none ],
      [ "Review this statement and set Groceries to $900", nil ]
    ]

    cases.each do |message, resolver_result|
      assert_unresolved_attached_account_action(
        needs_clarification: false,
        message: message,
        expected_evidence_prompt: "Review this statement",
        resolver_result: resolver_result
      )
    end
  end

  test "informational attachment questions retain their full prompt without a write boundary" do
    [
      "Review this statement. Could you update me on which spending category increased?",
      "Review this statement. Can you increase my understanding of this budget?",
      "Review this statement. Why did spending increase?",
      "Review this statement. What category increased?",
      "Review this statement and add up my spending"
    ].each do |message|
      assert_attached_evidence_only(message)
    end
  end

  test "attachment evidence math does not become a household mutation request" do
    user = create_user(email: "mia-attachment-evidence-math@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    category = household.budget_categories.create!(name: "Groceries", stack_key: "discretionary", sort_order: 1)
    document_import = household.financial_document_imports.create!(
      uploaded_by_user: user,
      document_kind: "statement",
      status: "needs_review",
      filename: "math-statement.pdf",
      content_type: "application/pdf",
      byte_size: 128,
      s3_key: "household-cfo/test/math-statement.pdf"
    )
    document_import.transaction_drafts.create!(
      household: household,
      occurred_on: Date.current,
      merchant: "Pay-Less",
      total_amount_cents: 87_45,
      budget_category: category,
      source_type: "statement",
      status: "pending",
      raw_input: "statement row"
    )
    message = "Summarize this statement and add up my spending"
    controller = Api::V1::MiaMessagesController.new
    assert controller.send(:pure_attachment_review_request?, message)
    refute controller.send(:attachment_action_request?, message)

    assert_no_difference([ "MiaActionDraft.count", "HouseholdTransaction.count", "BudgetYear.count", "BudgetAllocation.count" ]) do
      post "/api/v1/mia/messages",
           params: { message: message, document_import_ids: [ document_import.id ] },
           headers: auth_headers(user),
           as: :json
    end

    assert_response :created
    body = response.parsed_body
    assert_includes body.dig("assistant_message", "content"), "1 transaction row totaling $87.45"
    assert_not_includes body.dig("assistant_message", "content"), "Send the change as a new message"
    assert_nil body.fetch("mia_action_draft")
    assert_nil body.fetch("budget")
  end

  test "attachment evidence questions that mention action words remain read only" do
    controller = Api::V1::MiaMessagesController.new

    [
      "Review this statement. Why did spending increase?",
      "Review this statement. What category increased?",
      "Review this statement and add up my spending"
    ].each do |message|
      assert controller.send(:pure_attachment_review_request?, message), "did not keep #{message.inspect} evidence-only"
      refute controller.send(:attachment_action_request?, message), "incorrectly detected a household mutation in #{message.inspect}"
    end
  end

  test "mia chat answers an attachment question from pending structured evidence" do
    user = create_user(email: "mia-attachment-question@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    category = household.budget_categories.create!(name: "Groceries", stack_key: "discretionary", sort_order: 1)
    document_import = household.financial_document_imports.create!(
      uploaded_by_user: user,
      document_kind: "statement",
      status: "needs_review",
      filename: "statement.pdf",
      content_type: "application/pdf",
      byte_size: 128,
      s3_key: "household-cfo/test/question-statement.pdf"
    )
    document_import.transaction_drafts.create!(
      household: household,
      occurred_on: Date.new(2026, 7, 3),
      merchant: "Pay-Less",
      total_amount_cents: 87_45,
      budget_category: category,
      source_type: "statement",
      status: "pending",
      raw_input: "statement row"
    )

    assert_no_difference([ "HouseholdTransaction.count", "MiaActionDraft.count", "BudgetYear.count", "BudgetAllocation.count" ]) do
      post "/api/v1/mia/messages",
           params: { message: "What is the total and which merchant is in this attachment?", document_import_ids: [ document_import.id ], request_id: "attachment-question-1" },
           headers: auth_headers(user),
           as: :json
    end

    assert_response :created
    content = JSON.parse(response.body).dig("assistant_message", "content")
    assert_includes content, "1 transaction row totaling $87.45"
    assert_includes content, "Pay-Less — $87.45"
    assert_includes content, "pending review"
    assert_includes content, "not actuals"
    assert_not_includes content, "could not safely prepare"

    assert_no_difference("ChatMessage.count") do
      post "/api/v1/mia/messages",
           params: { message: "What is the total and which merchant is in this attachment?", document_import_ids: [ document_import.id ], request_id: "attachment-question-1" },
           headers: auth_headers(user),
           as: :json
    end
    assert_response :created
  end

  test "mia chat rejects an attachment ID outside the current household without routing the question" do
    user = create_user(email: "mia-attachment-owner@example.com")
    other_user = create_user(email: "mia-attachment-other@example.com")
    other_household = HouseholdFinance::WorkspaceResolver.new(other_user).household
    other_import = other_household.financial_document_imports.create!(
      uploaded_by_user: other_user,
      document_kind: "statement",
      status: "needs_review",
      filename: "private-statement.pdf",
      content_type: "application/pdf",
      byte_size: 128,
      s3_key: "household-cfo/test/private-statement.pdf"
    )

    assert_no_difference([ "ChatMessage.count", "MiaMessageRequest.count" ]) do
      post "/api/v1/mia/messages",
           params: { message: "What is the total?", document_import_ids: [ other_import.id ], request_id: "cross-household-attachment" },
           headers: auth_headers(user),
           as: :json
    end

    assert_response :unprocessable_entity
    assert_equal [ "One or more attached uploads are unavailable in this household." ], JSON.parse(response.body).fetch("errors")
    assert_not_includes response.body, "private-statement"
  end

  test "mia chat rejects more than five attachment IDs instead of silently dropping evidence" do
    user = create_user(email: "mia-too-many-attachments@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    imports = 6.times.map do |index|
      household.financial_document_imports.create!(
        uploaded_by_user: user,
        document_kind: "statement",
        status: "needs_review",
        filename: "statement-#{index}.pdf",
        content_type: "application/pdf",
        byte_size: 128,
        s3_key: "household-cfo/test/statement-#{index}.pdf"
      )
    end

    assert_no_difference([ "ChatMessage.count", "MiaMessageRequest.count" ]) do
      post "/api/v1/mia/messages",
           params: { message: "What is the total?", document_import_ids: imports.map(&:id), request_id: "too-many-attachments" },
           headers: auth_headers(user),
           as: :json
    end

    assert_response :unprocessable_entity
    assert_equal [ "Attach up to 5 uploads to one Mia message." ], JSON.parse(response.body).fetch("errors")
  end

  test "mia attachment plan-fit answer stays read-only when no confirmed plan exists" do
    user = create_user(email: "mia-plan-fit-missing@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    category = household.budget_categories.create!(name: "Groceries", stack_key: "discretionary", sort_order: 1)
    document_import = create_mia_attachment_import(household, user, "missing-plan")
    create_mia_attachment_draft(document_import, household, category: category, amount_cents: 8_745, occurred_on: Date.new(2026, 8, 2))

    assert_no_difference([ "BudgetYear.count", "BudgetPeriod.count", "BudgetAllocation.count", "ExpenseItem.count", "HouseholdTransaction.count", "MiaActionDraft.count" ]) do
      post "/api/v1/mia/messages",
           params: { message: "Does this grocery receipt fit my plan?", document_import_ids: [ document_import.id ] },
           headers: auth_headers(user), as: :json
    end

    assert_response :created
    content = JSON.parse(response.body).dig("assistant_message", "content")
    assert_includes content, "I can verify $87.45 in the attached pending evidence"
    assert_includes content, "there is no confirmed annual plan"
    assert_includes content, "cannot safely say whether it fits"
  end

  test "mia attachment plan-fit controller covers within over split uncategorized and multiple uploads" do
    user = create_user(email: "mia-plan-fit-matrix@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    groceries = household.budget_categories.create!(name: "Groceries", stack_key: "discretionary", sort_order: 1)
    dining = household.budget_categories.create!(name: "Dining", stack_key: "discretionary", sort_order: 2)
    manager = HouseholdFinance::AnnualBudgetManager.new(household, year: 2026)
    budget_year = manager.ensure_plan!
    set_mia_plan_allocation(budget_year, groceries, month: 8, cents: 10_000)
    set_mia_plan_allocation(budget_year, dining, month: 9, cents: 5_000)
    set_mia_plan_allocation(budget_year, groceries, month: 10, cents: 10_000)
    set_mia_plan_allocation(budget_year, dining, month: 10, cents: 8_000)
    set_mia_plan_allocation(budget_year, groceries, month: 12, cents: 10_000)

    within_import = create_mia_attachment_import(household, user, "within-plan")
    create_mia_attachment_draft(within_import, household, category: groceries, amount_cents: 4_000, occurred_on: Date.new(2026, 8, 2))
    post "/api/v1/mia/messages", params: { message: "Does this grocery receipt fit my plan?", document_import_ids: [ within_import.id ] }, headers: auth_headers(user), as: :json
    assert_response :created
    assert_includes JSON.parse(response.body).dig("assistant_message", "content"), "Groceries would remain within plan with $60.00 left"

    over_import = create_mia_attachment_import(household, user, "over-plan")
    create_mia_attachment_draft(over_import, household, category: dining, amount_cents: 7_000, occurred_on: Date.new(2026, 9, 2))
    post "/api/v1/mia/messages", params: { message: "Does this dining receipt fit my plan?", document_import_ids: [ over_import.id ] }, headers: auth_headers(user), as: :json
    assert_response :created
    assert_includes JSON.parse(response.body).dig("assistant_message", "content"), "Dining would be $20.00 over plan"

    split_import = create_mia_attachment_import(household, user, "split-plan")
    split_draft = create_mia_attachment_draft(split_import, household, category: nil, amount_cents: 5_000, occurred_on: Date.new(2026, 10, 2))
    split_draft.transaction_draft_splits.create!(budget_category: groceries, category_name: "Groceries", stack_key: "discretionary", amount_cents: 3_000)
    split_draft.transaction_draft_splits.create!(budget_category: dining, category_name: "Dining", stack_key: "discretionary", amount_cents: 2_000)
    post "/api/v1/mia/messages", params: { message: "Does this receipt fit my plan?", document_import_ids: [ split_import.id ] }, headers: auth_headers(user), as: :json
    assert_response :created
    split_content = JSON.parse(response.body).dig("assistant_message", "content")
    assert_includes split_content, "Groceries would remain within plan with $70.00 left"
    assert_includes split_content, "Dining would remain within plan with $60.00 left"

    uncategorized_import = create_mia_attachment_import(household, user, "uncategorized-plan")
    create_mia_attachment_draft(uncategorized_import, household, category: nil, amount_cents: 2_500, occurred_on: Date.new(2026, 11, 2))
    post "/api/v1/mia/messages", params: { message: "Does this receipt fit my plan?", document_import_ids: [ uncategorized_import.id ] }, headers: auth_headers(user), as: :json
    assert_response :created
    assert_includes JSON.parse(response.body).dig("assistant_message", "content"), "category is not matched to an approved plan category"

    multi_import_one = create_mia_attachment_import(household, user, "multi-one")
    multi_import_two = create_mia_attachment_import(household, user, "multi-two")
    create_mia_attachment_draft(multi_import_one, household, category: groceries, amount_cents: 1_000, occurred_on: Date.new(2026, 12, 2))
    create_mia_attachment_draft(multi_import_two, household, category: groceries, amount_cents: 2_000, occurred_on: Date.new(2026, 12, 3))
    post "/api/v1/mia/messages", params: { message: "Do these receipts fit my plan?", document_import_ids: [ multi_import_one.id, multi_import_two.id ] }, headers: auth_headers(user), as: :json
    assert_response :created
    assert_includes JSON.parse(response.body).dig("assistant_message", "content"), "Groceries would remain within plan with $70.00 left"
  end

  test "mia persistence bounds an oversized assistant response without failing the turn" do
    user = create_user(email: "mia-bounded-assistant@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    session = household.chat_sessions.create!(user: user, title: "Ask Mia")

    _user_message, assistant_message = Api::V1::MiaMessagesController.new.send(
      :persist_chat_messages,
      session,
      "Please give me the detailed plan.",
      [],
      "a" * (ChatMessage::MAX_ASSISTANT_CONTENT_LENGTH + 500)
    )

    assert_equal ChatMessage::MAX_ASSISTANT_CONTENT_LENGTH, assistant_message.content.length
    assert assistant_message.persisted?
  end

  test "mia chat reports one complete transaction total after every attached statement finishes" do
    user = create_user(email: "mia-complete-statements@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    category = household.budget_categories.create!(name: "Flexible spending", stack_key: "discretionary", sort_order: 1)
    imports = 2.times.map do |index|
      document_import = household.financial_document_imports.create!(
        uploaded_by_user: user,
        document_kind: "statement",
        status: "needs_review",
        filename: "statement-page-#{index + 1}.png",
        content_type: "image/png",
        byte_size: 128,
        s3_key: "household-cfo/test/statement-page-#{index + 1}.png"
      )
      2.times do |row|
        document_import.transaction_drafts.create!(
          household: household,
          occurred_on: Date.new(2026, 7, index * 2 + row + 1),
          merchant: "Statement merchant #{index}-#{row}",
          total_amount_cents: (index + row + 1) * 100,
          budget_category: category,
          source_type: "statement",
          status: "pending",
          raw_input: "Statement row"
        )
      end
      document_import
    end

    post "/api/v1/mia/messages",
         params: { message: "Review every statement row", document_import_ids: imports.map(&:id) },
         headers: auth_headers(user),
         as: :json

    assert_response :created
    assistant_content = JSON.parse(response.body).dig("assistant_message", "content")
    assert_includes assistant_content, "Finished reading all 2 uploads"
    assert_includes assistant_content, "4 pending transaction reviews"
    assert_includes assistant_content, "Every drafted row is available"
    assert_includes assistant_content, "actuals have not changed"
  end

  test "mia chat does not present partial attachment findings as complete" do
    user = create_user(email: "mia-processing-statements@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    completed = household.financial_document_imports.create!(
      uploaded_by_user: user,
      document_kind: "statement",
      status: "needs_review",
      filename: "complete-page.png",
      content_type: "image/png",
      byte_size: 128,
      s3_key: "household-cfo/test/complete-page.png"
    )
    completed.transaction_drafts.create!(
      household: household,
      occurred_on: Date.new(2026, 7, 1),
      merchant: "Completed merchant",
      total_amount_cents: 500,
      source_type: "statement",
      status: "pending",
      raw_input: "Completed row"
    )
    processing = household.financial_document_imports.create!(
      uploaded_by_user: user,
      document_kind: "statement",
      status: "processing",
      filename: "processing-page.png",
      content_type: "image/png",
      byte_size: 128,
      s3_key: "household-cfo/test/processing-page.png"
    )

    post "/api/v1/mia/messages",
         params: { message: "Review every statement row", document_import_ids: [ completed.id, processing.id ] },
         headers: auth_headers(user),
         as: :json

    assert_response :created
    assistant_content = JSON.parse(response.body).dig("assistant_message", "content")
    assert_includes assistant_content, "not reporting partial findings as complete"
    assert_not_includes assistant_content, "I created 1 pending transaction review"
  end

  test "mia attachment questions wait for every upload instead of answering from partial evidence" do
    user = create_user(email: "mia-processing-question@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    completed = household.financial_document_imports.create!(
      uploaded_by_user: user, document_kind: "statement", status: "needs_review", filename: "complete.png", content_type: "image/png", byte_size: 128, s3_key: "household-cfo/test/question-complete.png"
    )
    completed.transaction_drafts.create!(
      household: household, occurred_on: Date.new(2026, 7, 1), merchant: "Private partial merchant", total_amount_cents: 500_00, source_type: "statement", status: "pending", raw_input: "completed row"
    )
    processing = household.financial_document_imports.create!(
      uploaded_by_user: user, document_kind: "statement", status: "processing", filename: "processing.png", content_type: "image/png", byte_size: 128, s3_key: "household-cfo/test/question-processing.png"
    )

    post "/api/v1/mia/messages",
         params: { message: "What is the total across these uploads?", document_import_ids: [ completed.id, processing.id ] },
         headers: auth_headers(user),
         as: :json

    assert_response :created
    content = JSON.parse(response.body).dig("assistant_message", "content")
    assert_includes content, "not reporting partial findings as complete"
    assert_not_includes content, "$500.00"
    assert_not_includes content, "Private partial merchant"
  end

  test "mia attachment questions exclude failed imports and explain missing evidence" do
    user = create_user(email: "mia-failed-question@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    failed = household.financial_document_imports.create!(
      uploaded_by_user: user, document_kind: "statement", status: "failed", filename: "failed.pdf", content_type: "application/pdf", byte_size: 128, s3_key: "household-cfo/test/question-failed.pdf", extraction_error: "unsafe provider details"
    )
    failed.transaction_drafts.create!(
      household: household, occurred_on: Date.new(2026, 7, 1), merchant: "Stale merchant", total_amount_cents: 700_00, source_type: "statement", status: "pending", raw_input: "stale row"
    )

    post "/api/v1/mia/messages",
         params: { message: "What is the total in this upload?", document_import_ids: [ failed.id ] },
         headers: auth_headers(user),
         as: :json

    assert_response :created
    content = JSON.parse(response.body).dig("assistant_message", "content")
    assert_includes content, "failed extraction and produced no verified rows"
    assert_not_includes content, "$700.00"
    assert_not_includes content, "unsafe provider details"
  end

  test "mia chat explains budget uploads as review before apply setup values" do
    user = create_user(email: "mia-budget-upload@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    document_import = household.financial_document_imports.create!(
      uploaded_by_user: user,
      document_kind: "spreadsheet",
      status: "needs_review",
      filename: "household-budget.csv",
      content_type: "text/csv",
      byte_size: 256,
      s3_key: "household-cfo/test/household-budget.csv"
    )
    document_import.items.create!(target_type: "income_source", label: "Main income", amount_cents: 6_000_00, cadence: "monthly", confidence: "high", selected: true)
    document_import.items.create!(target_type: "expense_item", label: "Groceries", amount_cents: 900_00, cadence: "monthly", stack_key: "discretionary", confidence: "high", selected: true)

    nil_resolver = ->(**_kwargs) { Object.new.tap { |object| object.define_singleton_method(:call) { nil } } }
    with_singleton_stub(HouseholdFinance::MiaIntentResolver, :new, nil_resolver) do
      post "/api/v1/mia/messages",
           params: { message: "Can you set up my budget from this?", document_import_ids: [ document_import.id ] },
           headers: auth_headers(user),
           as: :json
    end

    assert_response :created
    body = JSON.parse(response.body)
    assistant_content = body.fetch("assistant_message").fetch("content")
    assert_not_includes assistant_content, "I used your note as context"
    assert_includes assistant_content, "budget/profile setup values"
    assert_includes assistant_content, "Main income and Groceries"
    assert_includes assistant_content, "open Review imports to approve or adjust"
    assert_includes assistant_content, "could not safely prepare"
    assert_nil body.fetch("budget")
  end

  test "unresolved one-clause upload setup and budget actions return an explicit no-write boundary" do
    user = create_user(email: "mia-budget-upload-action-boundary@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    document_import = household.financial_document_imports.create!(
      uploaded_by_user: user,
      document_kind: "spreadsheet",
      status: "needs_review",
      filename: "household-budget-action.csv",
      content_type: "text/csv",
      byte_size: 256,
      s3_key: "household-cfo/test/household-budget-action.csv"
    )
    document_import.items.create!(target_type: "expense_item", label: "Groceries", amount_cents: 900_00, cadence: "monthly", stack_key: "discretionary", confidence: "high", selected: true)
    nil_resolver = ->(**_kwargs) { Object.new.tap { |object| object.define_singleton_method(:call) { nil } } }

    [
      "Use this statement to update my budget",
      "Use this statement to set up my budget"
    ].each do |message|
      assert_no_difference([ "MiaActionDraft.count", "BudgetYear.count", "BudgetAllocation.count" ]) do
        with_singleton_stub(HouseholdFinance::MiaIntentResolver, :new, nil_resolver) do
          post "/api/v1/mia/messages",
               params: { message: message, document_import_ids: [ document_import.id ] },
               headers: auth_headers(user),
               as: :json
        end
      end

      assert_response :created
      body = response.parsed_body
      assert_includes body.dig("assistant_message", "content"), "could not safely prepare"
      assert_includes body.dig("assistant_message", "content"), "Nothing changed"
      assert_nil body.fetch("mia_action_draft")
      assert_nil body.fetch("budget")
    end
  end

  test "mia chat compacts conversation continuity for follow-up questions" do
    user = create_user(email: "mia-continuity@example.com")
    patch "/api/v1/workspace/setup",
          params: {
            workspace: {
              primary_income: 8_000,
              fixed_expenses: 4_000,
              flexible_spend: 1_000,
              emergency_fund: 8_000
            }
          },
          headers: auth_headers(user),
          as: :json

    household = HouseholdFinance::WorkspaceResolver.new(user).household
    household.household_profile.update!(
      debt_tracking_mode: "summary", debt_summary_balance_cents: 200_000,
      debt_summary_minimum_payment_cents: 15_000,
      debt_summary_balance_known: true, debt_summary_minimum_payment_known: true
    )
    confirm_setup_for_test(user)
    HouseholdFinance::AnnualBudgetManager.new(household).create_category!(name: "Dining Out", stack_key: "discretionary", monthly_amount: 300)

    post "/api/v1/mia/messages",
         params: { message: "My cousin asked for $200. Should I help?" },
         headers: auth_headers(user),
         as: :json
    assert_response :created

    session = user.households.first.chat_sessions.find_by!(user: user)
    assert_includes session.reload.rolling_summary, "Family support"
    assert_equal "family_support", session.active_topic.fetch("type")

    post "/api/v1/mia/messages",
         params: { message: "What if I cut dining out to cover it?" },
         headers: auth_headers(user),
         as: :json

    assert_response :created
    content = JSON.parse(response.body).fetch("assistant_message").fetch("content")
    assert_includes content, "family support"
    assert_includes content, "tradeoff"
    assert_includes content, "Dining Out"
    assert_includes content, "$200"
    refute_includes content, "I do not see confirmed Dining Out spending"
    assert_equal "family_support", session.reload.active_topic.fetch("type")
  end

  test "a complete conditional income question ignores a conflicting active topic without writing financial data" do
    user = create_user(email: "mia-conditional-income-new-topic@example.com")
    patch "/api/v1/workspace/setup",
          params: {
            workspace: {
              primary_income: 8_500,
              fixed_expenses: 6_925,
              flexible_spend: 0,
              emergency_fund: 25_090
            }
          },
          headers: auth_headers(user),
          as: :json
    assert_response :ok
    confirm_setup_for_test(user)

    household = HouseholdFinance::WorkspaceResolver.new(user).household
    household.household_profile.update!(
      debt_tracking_mode: "summary", debt_summary_balance_cents: 1_000_000,
      debt_summary_minimum_payment_cents: 92_000,
      debt_summary_balance_known: true, debt_summary_minimum_payment_known: true
    )
    HouseholdFinance::AnnualBudgetManager.new(household).ensure_plan!
    prior_topic = {
      schema_version: 2,
      id: SecureRandom.uuid,
      type: "bill_triage",
      title: "Bills before payday",
      subject: "rent and utilities",
      status: "open",
      latest_user_context: "I only have $1,200 and several bills due before payday.",
      latest_mia_summary: "Protect rent and utilities before optional spending.",
      next_move: "List each bill and pay the highest-consequence essential first."
    }
    session = household.chat_sessions.create!(user: user, title: "Ask Mia", active_topic: prior_topic, open_topics: [ prior_topic ])
    session.chat_messages.create!(role: "user", content: prior_topic.fetch(:latest_user_context))
    session.chat_messages.create!(role: "assistant", content: prior_topic.fetch(:latest_mia_summary))
    financial_state_before = {
      income: household.income_sources.order(:id).pluck(:id, :amount_cents, :cadence, :starts_on, :ends_on, :active),
      expenses: household.expense_items.order(:id).pluck(:id, :amount_cents, :cadence, :active),
      debts: household.debts.order(:id).pluck(:id, :balance_cents, :minimum_payment_cents)
    }
    message = "If our monthly income is $5,000, how much can we save?"
    nil_resolver = ->(**_kwargs) { Object.new.tap { |object| object.define_singleton_method(:call) { nil } } }

    assert_no_difference([ "MiaActionDraft.count", "HouseholdTransaction.count", "TransactionDraft.count" ]) do
      with_singleton_stub(HouseholdFinance::MiaIntentResolver, :new, nil_resolver) do
        post "/api/v1/mia/messages",
             params: { message: message },
             headers: auth_headers(user),
             as: :json
      end
    end

    assert_response :created
    body = response.parsed_body
    content = body.dig("assistant_message", "content")
    assert_includes content, "Assumption only"
    assert_includes content, "monthly income were $5,000"
    assert_includes content, "approved monthly outflow stayed $7,845"
    assert_includes content, "$2,845 monthly shortfall"
    assert_includes content, "approved recurring monthly income remains $8,500"
    assert_includes content, "did not save this scenario or change any household data"
    assert_not_includes content, "Start with the bill"
    assert_nil body.fetch("mia_action_draft")
    assert_nil body.fetch("transaction_draft")
    assert_equal message, session.chat_messages.where(role: "user").order(:id).last.content
    assert_equal prior_topic.fetch(:latest_user_context), session.reload.active_topic.fetch("latest_user_context")
    assert_equal financial_state_before.fetch(:income), household.reload.income_sources.order(:id).pluck(:id, :amount_cents, :cadence, :starts_on, :ends_on, :active)
    assert_equal financial_state_before.fetch(:expenses), household.expense_items.order(:id).pluck(:id, :amount_cents, :cadence, :active)
    assert_equal financial_state_before.fetch(:debts), household.debts.order(:id).pluck(:id, :balance_cents, :minimum_payment_cents)
  end

  test "mia chat can resume compacted context across requests and clear it" do
    user = create_user(email: "mia-resume-context@example.com")
    patch "/api/v1/workspace/setup",
          params: { workspace: { primary_income: 8_000, fixed_expenses: 4_000, emergency_fund: 8_000 } },
          headers: auth_headers(user),
          as: :json
    confirm_setup_for_test(user)

    post "/api/v1/mia/messages",
         params: { message: "Should I use emergency fund for a car repair?" },
         headers: auth_headers(user),
         as: :json
    assert_response :created

    post "/api/v1/mia/messages",
         params: { message: "It is $640 and I need it for work. What now?" },
         headers: auth_headers(user),
         as: :json

    assert_response :created
    content = JSON.parse(response.body).fetch("assistant_message").fetch("content")
    assert_includes content, "car repair"
    assert_includes content, "$640"

    post "/api/v1/mia/messages",
         params: { message: "Can you remind me what we were talking about?" },
         headers: auth_headers(user),
         as: :json

    assert_response :created
    reminder = JSON.parse(response.body).fetch("assistant_message").fetch("content")
    assert_includes reminder, "conversation context"
    assert_includes reminder, "Car repair"
    assert_includes reminder, "not financial truth"

    get "/api/v1/workspace", headers: auth_headers(user)
    assert_response :success
    assert_equal 6, JSON.parse(response.body).fetch("mia").fetch("messages").length

    delete "/api/v1/mia/messages", headers: auth_headers(user)
    assert_response :no_content
    session = user.households.first.chat_sessions.find_by!(user: user)
    assert_nil session.rolling_summary
    assert_empty session.open_topics
    assert_empty session.active_topic

    post "/api/v1/mia/messages",
         params: { message: "Can you remind me what we were talking about?" },
         headers: auth_headers(user),
         as: :json

    assert_response :created
    cleared_reminder = JSON.parse(response.body).fetch("assistant_message").fetch("content")
    assert_includes cleared_reminder, "I do not have an open chat topic to resume after the clear"
    assert_includes cleared_reminder, "Conversation continuity is context only"
  end

  test "model-routed recall keeps participant context after a persona version switch" do
    user = create_user(email: "mia-persona-version-recall@example.com")
    coach = create_user(email: "mia-persona-version-coach@example.com", role: "coach")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    session = household.chat_sessions.create!(user: user, title: "Ask Mia")
    persona = CoachPersona.create!(
      name: "Coach Lani",
      draft_config: Mia::PersonaSchema.default_configuration(
        assistant_name: "Auntie Lani",
        human_coach_name: "Mrs. Mel",
        human_coach_title: "Household CFO coach"
      ),
      created_by_user: coach
    )
    retired_version = publish_persona(persona, actor: coach)
    persona.update!(
      draft_config: persona.draft_config.deep_merge("identity" => { "assistant_name" => "Coach Lani" })
    )
    current_version = publish_persona(persona, actor: coach)
    topic = {
      schema_version: 3,
      id: SecureRandom.uuid,
      type: "purchase_scenario",
      title: "Furniture Purchase Scenario",
      subject: "furniture",
      status: "open",
      amount_label: "$700",
      latest_user_context: "I said I was considering spending $700 on furniture.",
      latest_mia_summary: "Repeat the retired assistant's exact wording.",
      next_move: "Use the retired assistant's favorite phrase.",
      assistant_persona_context_id: "coach_persona_version:#{retired_version.id}",
      assistant_persona_version_id: retired_version.id,
      read_only_plan: {
        version: 1,
        items: [
          {
            kind: "scenario",
            scenario_type: "purchase",
            scenario_label: "Furniture",
            amount: "700.00",
            source_text: "What if we spend $700 on furniture?",
            resolved_question: "What if we spend $700 on furniture next month?",
            basis: "scenario"
          }
        ]
      }
    }
    session.update!(active_topic: topic, open_topics: [ topic ])
    intent_result = HouseholdFinance::MiaIntentResolver::Result.new(
      intent: "recall",
      confidence: 0.99,
      continuation: true,
      resolved_message: "Remind me what I said I was considering.",
      needs_clarification: false,
      clarification: "",
      topic: { type: "purchase_scenario", title: "Furniture Purchase Scenario", subject: "furniture" },
      action: { type: "none" },
      source: "model"
    )
    fake_intent_resolver = ->(**_kwargs) { Object.new.tap { |object| object.define_singleton_method(:call) { intent_result } } }
    runtime_persona = Mia::RuntimePersona.new(current_version)
    fake_persona_resolver = ->(**_kwargs) { Object.new.tap { |object| object.define_singleton_method(:call) { runtime_persona } } }

    with_singleton_stub(Mia::PersonaResolver, :new, fake_persona_resolver) do
      with_singleton_stub(HouseholdFinance::MiaIntentResolver, :new, fake_intent_resolver) do
        post "/api/v1/mia/messages",
             params: { message: "Remind me what I said I was considering, then tell me the smallest next step without repeating an old assistant answer." },
             headers: auth_headers(user),
             as: :json
      end
    end

    assert_response :created
    assistant = response.parsed_body.fetch("assistant_message")
    assert_equal "Coach Lani", assistant.fetch("author")
    persisted_assistant = session.chat_messages.order(:id).last
    assert_equal current_version.id, persisted_assistant.coach_persona_version_id
    assert_includes assistant.fetch("content"), "Furniture Purchase Scenario"
    assert_includes assistant.fetch("content"), "$700"
    assert_includes assistant.fetch("content"), "pick the budget category and funding account"
    assert_not_includes assistant.fetch("content"), "retired assistant"
    assert_not_includes assistant.fetch("content"), "favorite phrase"
    assert_not_includes assistant.fetch("content"), "reveal"
  end

  test "mia chat still succeeds when conversation compaction fails" do
    user = create_user(email: "mia-compaction-failure@example.com")
    original_compactor_new = HouseholdFinance::ConversationCompactor.method(:new)

    begin
      HouseholdFinance::ConversationCompactor.define_singleton_method(:new) do |*|
        raise ActiveRecord::StatementInvalid, "simulated compaction failure"
      end

      assert_difference("ChatMessage.count", 2) do
        post "/api/v1/mia/messages",
             params: { message: "Can I leave my job?" },
             headers: auth_headers(user),
             as: :json
      end
    ensure
      HouseholdFinance::ConversationCompactor.define_singleton_method(:new, original_compactor_new)
    end

    assert_response :created
    body = JSON.parse(response.body)
    assert_equal "Can I leave my job?", body.fetch("user_message").fetch("content")
    assert body.fetch("assistant_message").fetch("content").present?
  end

  test "mia chat accepts exactly the storage limit and rejects one extra character without side effects" do
    user = create_user(email: "long-mia@example.com")
    exact = "a" * ChatMessage::MAX_CONTENT_LENGTH

    assert_difference({ "ChatMessage.count" => 2, "MiaMessageRequest.count" => 1 }) do
      assert_no_difference([ "MiaActionDraft.count", "MiaActionDraftApplication.count" ]) do
        post "/api/v1/mia/messages",
          params: { message: exact, request_id: "mia-exact-message-limit" },
          headers: auth_headers(user),
          as: :json
      end
    end
    assert_response :created
    assert_equal exact, response.parsed_body.dig("user_message", "content")

    assert_no_difference([ "ChatMessage.count", "MiaMessageRequest.count", "MiaActionDraft.count", "MiaActionDraftApplication.count" ]) do
      post "/api/v1/mia/messages",
           params: { message: "a" * (ChatMessage::MAX_CONTENT_LENGTH + 1), request_id: "mia-over-message-limit" },
           headers: auth_headers(user),
           as: :json
    end

    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body).fetch("errors"), "Message is too long (maximum is #{ChatMessage::MAX_CONTENT_LENGTH} characters)"
  end

  test "mia chat does not persist orphaned user message if assistant message fails" do
    user = create_user(email: "atomic-mia@example.com")

    failing_responder = Class.new do
      def call(*)
        ""
      end
    end.new

    original_responder = Demo::MiaResponder.method(:new)
    begin
      Demo::MiaResponder.define_singleton_method(:new) { |*, **| failing_responder }

      assert_no_difference("ChatMessage.count") do
        post "/api/v1/mia/messages",
             params: { message: "Can Mia save atomically?" },
             headers: auth_headers(user),
             as: :json
      rescue ActiveRecord::RecordInvalid
        nil
      end
    ensure
      Demo::MiaResponder.define_singleton_method(:new, original_responder)
    end

    session = user.households.first.chat_sessions.find_by(user: user)
    assert session.present?
    assert_empty session.chat_messages
  end

  test "mia chat returns the complete persisted history when it fits on one page" do
    user = create_user(email: "full-chat-history@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    session = household.chat_sessions.create!(user: user, title: "Ask Mia")
    30.times do |index|
      session.chat_messages.create!(role: index.even? ? "user" : "assistant", content: "Persisted message #{index + 1}")
    end

    get "/api/v1/mia/messages", headers: auth_headers(user)

    assert_response :success
    messages = JSON.parse(response.body).fetch("messages")
    assert_equal 30, messages.length
    assert_equal "Persisted message 1", messages.first.fetch("content")
    assert_equal "Persisted message 30", messages.last.fetch("content")
    assert_equal 0, JSON.parse(response.body).fetch("older_message_count")
  end

  test "mia chat paginates older history without returning every attachment on each poll" do
    user = create_user(email: "paginated-chat-history@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    session = household.chat_sessions.create!(user: user, title: "Ask Mia")
    125.times do |index|
      session.chat_messages.create!(role: index.even? ? "user" : "assistant", content: "Persisted message #{index + 1}")
    end

    get "/api/v1/mia/messages", params: { limit: 60 }, headers: auth_headers(user)

    assert_response :success
    first_page = JSON.parse(response.body)
    assert_equal 60, first_page.fetch("messages").length
    assert_equal "Persisted message 66", first_page.fetch("messages").first.fetch("content")
    assert_equal "Persisted message 125", first_page.fetch("messages").last.fetch("content")
    assert_equal 65, first_page.fetch("older_message_count")
    assert_equal true, first_page.fetch("has_older_messages")

    get "/api/v1/mia/messages", params: { before_id: first_page.fetch("oldest_message_id"), limit: 60 }, headers: auth_headers(user)

    assert_response :success
    second_page = JSON.parse(response.body)
    assert_equal 60, second_page.fetch("messages").length
    assert_equal "Persisted message 6", second_page.fetch("messages").first.fetch("content")
    assert_equal "Persisted message 65", second_page.fetch("messages").last.fetch("content")
    assert_equal 5, second_page.fetch("older_message_count")
  end

  test "mia chat history can be cleared" do
    user = create_user(email: "clear@example.com")
    post "/api/v1/mia/messages",
         params: { message: "test", request_id: "mia-request-clear-1" },
         headers: auth_headers(user),
         as: :json
    assert_equal 1, MiaMessageRequest.count

    delete "/api/v1/mia/messages", headers: auth_headers(user)

    assert_response :no_content

    get "/api/v1/mia/messages", headers: auth_headers(user)

    assert_response :success
    assert_empty JSON.parse(response.body).fetch("messages")
    assert_equal 0, MiaMessageRequest.count
  end

  test "clearing Mia chat waits for active requests instead of allowing a late turn to restore history" do
    user = create_user(email: "clear-active-request@example.com")
    post "/api/v1/mia/messages",
         params: { message: "Keep this turn", request_id: "mia-request-before-active-clear-1" },
         headers: auth_headers(user),
         as: :json
    assert_response :created

    household = HouseholdFinance::WorkspaceResolver.new(user).household
    session = household.chat_sessions.find_by!(user: user)
    active_request = session.mia_message_requests.create!(
      request_key: "mia-request-active-clear-1",
      request_fingerprint: "a" * 64
    )

    assert_no_difference([ "ChatMessage.count", "MiaMessageRequest.count" ]) do
      delete "/api/v1/mia/messages", headers: auth_headers(user)
    end

    assert_response :conflict
    assert_equal "mia_request_processing", JSON.parse(response.body).fetch("code")
    assert MiaMessageRequest.exists?(active_request.id)
    assert active_request.reload.processing?
  end

  test "clearing Mia chat expires abandoned requests instead of blocking forever" do
    user = create_user(email: "clear-stale-request@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    session = household.chat_sessions.create!(user: user, title: "Ask Mia")
    stale_request = session.mia_message_requests.create!(
      request_key: "mia-request-stale-clear-1",
      request_fingerprint: "a" * 64
    )
    stale_request.update_column(:updated_at, 4.minutes.ago)

    delete "/api/v1/mia/messages", headers: auth_headers(user)

    assert_response :no_content
    refute MiaMessageRequest.exists?(stale_request.id)
  end

  test "clearing empty Mia chat does not create a chat session" do
    user = create_user(email: "no-session-clear@example.com")

    assert_no_difference("ChatSession.count") do
      delete "/api/v1/mia/messages", headers: auth_headers(user)
    end

    assert_response :no_content
  end

  test "mia answers successive attachment evidence follow-ups without reattaching" do
    user = create_user(email: "mia-prior-evidence-followups@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    confirm_setup_for_test(user)
    groceries = household.budget_categories.create!(name: "Groceries", stack_key: "discretionary", sort_order: 1)
    dining = household.budget_categories.create!(name: "Dining", stack_key: "discretionary", sort_order: 2)
    budget_year = HouseholdFinance::AnnualBudgetManager.new(household, year: Date.current.year).ensure_plan!
    set_mia_plan_allocation(budget_year, groceries, month: Date.current.month, cents: 50_000)
    set_mia_plan_allocation(budget_year, groceries, month: Date.current.prev_month.month, cents: 50_000)
    document_import = create_mia_attachment_import(household, user, "followup-receipt")
    create_mia_attachment_draft(document_import, household, category: groceries, amount_cents: 12_00, occurred_on: Date.current.prev_month.beginning_of_month + 3.days)
    create_mia_attachment_draft(document_import, household, category: groceries, amount_cents: 25_00, occurred_on: Date.current.beginning_of_month)
    create_mia_attachment_draft(document_import, household, category: dining, amount_cents: 100_00, occurred_on: Date.current.prev_month.beginning_of_month + 4.days)

    post "/api/v1/mia/messages",
         params: { message: "What is the total in this upload?", document_import_ids: [ document_import.id ] },
         headers: auth_headers(user),
         as: :json
    assert_response :created

    session = household.chat_sessions.find_by!(user: user)
    evidence = session.reload.active_topic.fetch("document_evidence")
    assert_equal 1, evidence.fetch("schema_version")
    assert_equal [ document_import.id ], evidence.fetch("financial_document_import_ids")
    assert_equal %w[financial_document_import_ids import_count schema_version], evidence.keys.sort
    financial_counts = [ BudgetYear, BudgetPeriod, BudgetAllocation, ExpenseItem, HouseholdTransaction, TransactionDraft, MiaActionDraft ]
      .index_with(&:count)

    assert_no_difference([ "BudgetYear.count", "BudgetPeriod.count", "BudgetAllocation.count", "ExpenseItem.count", "HouseholdTransaction.count", "TransactionDraft.count", "MiaActionDraft.count" ]) do
      post "/api/v1/mia/messages",
           params: { message: "What about groceries?", request_id: "prior-evidence-groceries" },
           headers: auth_headers(user),
           as: :json
    end
    assert_response :created
    groceries_answer = response.parsed_body.dig("assistant_message", "content")
    assert_includes groceries_answer, "Using your prior upload"
    assert_includes groceries_answer, "$37"

    post "/api/v1/mia/messages",
         params: { message: "Only last month?", request_id: "prior-evidence-last-month" },
         headers: auth_headers(user),
         as: :json
    assert_response :created
    last_month_answer = response.parsed_body.dig("assistant_message", "content")
    assert_includes last_month_answer, "Using your prior upload"
    assert_includes last_month_answer, "$12"
    assert_not_includes last_month_answer, "$37"

    post "/api/v1/mia/messages",
         params: { message: "Does that fit my plan?", request_id: "prior-evidence-plan-fit" },
         headers: auth_headers(user),
         as: :json
    assert_response :created
    plan_answer = response.parsed_body.dig("assistant_message", "content")
    assert_includes plan_answer, "Using your prior upload"
    assert_includes plan_answer, "would remain within plan"
    assert_not_includes plan_answer, "Dining"
    assert_equal financial_counts, financial_counts.keys.index_with(&:count)

    assert_no_difference("ChatMessage.count") do
      post "/api/v1/mia/messages",
           params: { message: "Does that fit my plan?", request_id: "prior-evidence-plan-fit" },
           headers: auth_headers(user),
           as: :json
    end
    assert_response :created
    assert_equal plan_answer, response.parsed_body.dig("assistant_message", "content")

    session = household.chat_sessions.find_by!(user: user)
    topic_before_invalid_replay = session.reload.attributes.slice("active_topic", "open_topics", "rolling_summary")
    document_import.update!(status: "processing")
    assert_no_difference([ "ChatMessage.count", "MiaMessageRequest.count", "BudgetYear.count", "BudgetPeriod.count", "BudgetAllocation.count" ]) do
      post "/api/v1/mia/messages",
           params: { message: "Does that fit my plan?", request_id: "prior-evidence-plan-fit" },
           headers: auth_headers(user),
           as: :json
    end
    assert_response :created
    assert_equal plan_answer, response.parsed_body.dig("assistant_message", "content")
    assert_equal topic_before_invalid_replay, session.reload.attributes.slice("active_topic", "open_topics", "rolling_summary")
    document_import.update!(status: "needs_review")

    post "/api/v1/mia/messages",
         params: { message: "What is the total in the whole upload?" },
         headers: auth_headers(user),
         as: :json
    assert_response :created
    whole_upload_answer = response.parsed_body.dig("assistant_message", "content")
    assert_includes whole_upload_answer, "Using your prior upload"
    assert_includes whole_upload_answer, "$137"
    assert_not_includes whole_upload_answer, "matching that merchant, category, date, or amount filter"
  end

  test "attachment evidence survives bounded transcript compaction but retires on an unrelated topic" do
    user = create_user(email: "mia-prior-evidence-compaction@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    confirm_setup_for_test(user)
    category = household.budget_categories.create!(name: "Groceries", stack_key: "discretionary", sort_order: 1)
    document_import = create_mia_attachment_import(household, user, "compacted-evidence")
    create_mia_attachment_draft(document_import, household, category: category, amount_cents: 42_00, occurred_on: Date.current.prev_month)

    post "/api/v1/mia/messages",
         params: { message: "What is the total in this upload?", document_import_ids: [ document_import.id ] },
         headers: auth_headers(user),
         as: :json
    assert_response :created
    session = household.chat_sessions.find_by!(user: user)
    40.times do |index|
      session.chat_messages.create!(role: index.even? ? "user" : "assistant", content: "Compacted filler #{index}")
    end

    post "/api/v1/mia/messages", params: { message: "Only last month?" }, headers: auth_headers(user), as: :json
    assert_response :created
    assert_includes response.parsed_body.dig("assistant_message", "content"), "$42"

    post "/api/v1/mia/messages",
         params: { message: "What should my groceries budget be next month?" },
         headers: auth_headers(user),
         as: :json
    assert_response :created
    assert_not_includes response.parsed_body.dig("assistant_message", "content"), "Using your prior upload"
    session.reload
    refute HouseholdFinance::DocumentEvidenceContinuity.topic?(session.active_topic)
    refute session.open_topics.any? { |topic| HouseholdFinance::DocumentEvidenceContinuity.topic?(topic) }
  end

  test "prior attachment evidence fails closed when imports stop being eligible and clear chat removes it" do
    user = create_user(email: "mia-prior-evidence-invalid@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    category = household.budget_categories.create!(name: "Groceries", stack_key: "discretionary", sort_order: 1)
    document_import = create_mia_attachment_import(household, user, "invalidated-evidence")
    create_mia_attachment_draft(document_import, household, category: category, amount_cents: 31_00, occurred_on: Date.current)

    post "/api/v1/mia/messages",
         params: { message: "What is the total in this upload?", document_import_ids: [ document_import.id ] },
         headers: auth_headers(user),
         as: :json
    assert_response :created
    session = household.chat_sessions.find_by!(user: user)
    assert HouseholdFinance::DocumentEvidenceContinuity.topic?(session.reload.active_topic)

    document_import.update!(status: "processing")
    assert_no_difference([ "BudgetYear.count", "BudgetPeriod.count", "BudgetAllocation.count", "ChatMessage.count", "MiaActionDraft.count", "TransactionDraft.count" ]) do
      post "/api/v1/mia/messages", params: { message: "What about groceries?" }, headers: auth_headers(user), as: :json
    end
    assert_response :conflict
    assert_equal "mia_document_evidence_unavailable", response.parsed_body.fetch("code")
    refute [ session.reload.active_topic, *session.open_topics ].any? { |topic| HouseholdFinance::DocumentEvidenceContinuity.topic?(topic) }

    document_import.update!(status: "needs_review")
    post "/api/v1/mia/messages",
         params: { message: "What is the total in this upload?", document_import_ids: [ document_import.id ] },
         headers: auth_headers(user),
         as: :json
    assert_response :created
    session.reload
    assert [ session.active_topic, *session.open_topics ].any? { |topic| HouseholdFinance::DocumentEvidenceContinuity.topic?(topic) }

    delete "/api/v1/mia/messages", headers: auth_headers(user)
    assert_response :no_content
    assert_empty session.reload.active_topic
    assert_empty session.open_topics
  end

  test "invalid prior attachment continuations never fall through to plan creation or chat persistence" do
    variants = {
      "processing" => ->(document_import) { document_import.update!(status: "processing") },
      "failed" => ->(document_import) { document_import.update!(status: "failed") },
      "source_deleted_needs_review" => lambda do |document_import|
        document_import.update_columns(source_deleted_at: Time.current, s3_key: nil)
      end,
      "source_deleted_applied" => lambda do |document_import|
        document_import.update_columns(status: "applied", source_deleted_at: Time.current, s3_key: nil)
      end,
      "source_deleted_partially_applied" => lambda do |document_import|
        document_import.update_columns(status: "partially_applied", source_deleted_at: Time.current, s3_key: nil)
      end
    }
    financial_models = [
      BudgetYear, BudgetPeriod, BudgetAllocation, BudgetCategory, ExpenseItem, HouseholdTransaction,
      IncomeSource, IncomeScheduleEntry, Account, Debt, Goal, MiaActionDraft, TransactionDraft,
      FinancialDocumentImportItem, ChatMessage, MiaMessageRequest
    ]

    variants.each_with_index do |(label, invalidate), index|
      user = create_user(email: "mia-invalid-prior-evidence-#{index}@example.com")
      household = HouseholdFinance::WorkspaceResolver.new(user).household
      category = household.budget_categories.create!(name: "Groceries", stack_key: "discretionary", sort_order: 1)
      document_import = create_mia_attachment_import(household, user, "invalid-prior-#{index}")
      create_mia_attachment_draft(document_import, household, category: category, amount_cents: 25_00, occurred_on: Date.current)
      topic = {
        schema_version: 4,
        id: SecureRandom.uuid,
        type: "document_evidence",
        title: "Prior upload",
        subject: "uploaded financial documents",
        status: "open",
        document_evidence: {
          schema_version: 1,
          financial_document_import_ids: [ document_import.id ],
          import_count: 1,
          query_scope: { entities: [ "groceries" ] }
        }
      }
      session = household.chat_sessions.create!(user: user, title: "Ask Mia", active_topic: topic, open_topics: [ topic ])
      invalidate.call(document_import)
      counts = financial_models.index_with(&:count)

      post "/api/v1/mia/messages",
           params: { message: "Does that fit my plan?" },
           headers: auth_headers(user),
           as: :json

      assert_response :conflict, label
      assert_equal "mia_document_evidence_unavailable", response.parsed_body.fetch("code"), label
      assert_includes response.parsed_body.fetch("error"), "Re-upload", label
      assert_equal counts, financial_models.index_with(&:count), label
      session.reload
      refute HouseholdFinance::DocumentEvidenceContinuity.topic?(session.active_topic), label
      refute session.open_topics.any? { |candidate| HouseholdFinance::DocumentEvidenceContinuity.topic?(candidate) }, label
    end
  end

  test "an in-flight attachment follow-up keeps idempotent processing precedence after evidence becomes invalid" do
    user = create_user(email: "mia-invalid-evidence-processing-replay@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    document_import = create_mia_attachment_import(household, user, "processing-replay")
    topic = {
      schema_version: 4,
      id: SecureRandom.uuid,
      type: "document_evidence",
      title: "Prior upload",
      subject: "uploaded financial documents",
      status: "open",
      document_evidence: {
        schema_version: 1,
        financial_document_import_ids: [ document_import.id ],
        import_count: 1
      }
    }
    session = household.chat_sessions.create!(user: user, title: "Ask Mia", active_topic: topic, open_topics: [ topic ])
    content = "Does that fit my plan?"
    fingerprint = Digest::SHA256.hexdigest(
      { message: content, year: Date.current.year, month: Date.current.month, document_import_ids: [] }.to_json
    )
    session.mia_message_requests.create!(request_key: "invalid-evidence-processing-replay", request_fingerprint: fingerprint)
    document_import.update!(status: "processing")
    topic_before_replay = session.reload.attributes.slice("active_topic", "open_topics", "rolling_summary")

    assert_no_difference([ "ChatMessage.count", "MiaMessageRequest.count", "BudgetYear.count", "BudgetPeriod.count", "BudgetAllocation.count" ]) do
      post "/api/v1/mia/messages",
           params: { message: content, request_id: "invalid-evidence-processing-replay" },
           headers: auth_headers(user),
           as: :json
    end

    assert_response :accepted
    assert_equal "mia_request_processing", response.parsed_body.fetch("code")
    assert_equal topic_before_replay, session.reload.attributes.slice("active_topic", "open_topics", "rolling_summary")
  end

  private

  def assert_unresolved_attached_account_action(needs_clarification:, message: "Review this statement and update my checking account", expected_evidence_prompt: "Review this statement", resolver_result: :action_none)
    user = create_user(email: "mia-attached-account-#{needs_clarification ? 'clarification' : 'unresolved'}-#{SecureRandom.hex(4)}@example.com")
    confirm_setup_for_test(user)
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    category = household.budget_categories.create!(name: "Groceries", stack_key: "discretionary", sort_order: 1)
    document_import = household.financial_document_imports.create!(
      uploaded_by_user: user,
      document_kind: "statement",
      status: "needs_review",
      filename: "checking-statement.pdf",
      content_type: "application/pdf",
      byte_size: 128,
      s3_key: "household-cfo/test/checking-statement-#{SecureRandom.hex(4)}.pdf"
    )
    document_import.transaction_drafts.create!(
      household: household,
      occurred_on: Date.current,
      merchant: "Pay-Less",
      total_amount_cents: 87_45,
      budget_category: category,
      source_type: "statement",
      status: "pending",
      raw_input: "statement row"
    )
    intent_result = if resolver_result == :action_none
      HouseholdFinance::MiaIntentResolver::Result.new(
        intent: "asset_action",
        confidence: 0.99,
        continuation: false,
        resolved_message: "Update my checking account",
        needs_clarification: needs_clarification,
        clarification: needs_clarification ? "Which checking account should I update?" : "",
        topic: { type: "asset_edit", title: "Checking account update", subject: "checking account" },
        action: { type: "none" },
        read_only_plan: {},
        source: "model"
      )
    end
    fake_resolver = ->(**_kwargs) { Object.new.tap { |object| object.define_singleton_method(:call) { intent_result } } }
    controller = Api::V1::MiaMessagesController
    original_evidence_prompt = controller.instance_method(:attached_document_evidence_prompt)
    captured_evidence_prompts = []

    controller.define_method(:attached_document_evidence_prompt) do |content, result|
      prompt = original_evidence_prompt.bind_call(self, content, result)
      captured_evidence_prompts << prompt
      prompt
    end

    assert_no_difference([ "MiaActionDraft.count", "HouseholdTransaction.count" ]) do
      with_singleton_stub(HouseholdFinance::MiaIntentResolver, :new, fake_resolver) do
        post "/api/v1/mia/messages",
             params: { message: message, document_import_ids: [ document_import.id ] },
             headers: auth_headers(user),
             as: :json
      end
    end

    assert_response :created
    body = response.parsed_body
    assistant_content = body.dig("assistant_message", "content")
    assert_includes assistant_content, "Finished reading the statement upload."
    assert_includes assistant_content, "Send the change as a new message without an attachment"
    assert_nil body.fetch("mia_action_draft")
    assert_nil body.fetch("budget")
    assert_equal message, body.dig("user_message", "content")
    assert_equal document_import.id, body.dig("user_message", "attachments", 0, "document_import_id")
    assert_equal [ expected_evidence_prompt ], captured_evidence_prompts

    session = household.chat_sessions.find_by!(user: user)
    evidence = session.reload.active_topic.fetch("document_evidence")
    assert_equal [ document_import.id ], evidence.fetch("financial_document_import_ids")
  ensure
    controller&.define_method(:attached_document_evidence_prompt, original_evidence_prompt) if original_evidence_prompt
  end

  def assert_attached_evidence_only(message)
    user = create_user(email: "mia-attached-evidence-only-#{SecureRandom.hex(4)}@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    category = household.budget_categories.create!(name: "Groceries", stack_key: "discretionary", sort_order: 1)
    document_import = household.financial_document_imports.create!(
      uploaded_by_user: user,
      document_kind: "statement",
      status: "needs_review",
      filename: "evidence-only-statement.pdf",
      content_type: "application/pdf",
      byte_size: 128,
      s3_key: "household-cfo/test/evidence-only-statement-#{SecureRandom.hex(4)}.pdf"
    )
    document_import.transaction_drafts.create!(
      household: household,
      occurred_on: Date.current,
      merchant: "Pay-Less",
      total_amount_cents: 87_45,
      budget_category: category,
      source_type: "statement",
      status: "pending",
      raw_input: "statement row"
    )
    nil_resolver = ->(**_kwargs) { Object.new.tap { |object| object.define_singleton_method(:call) { nil } } }
    controller = Api::V1::MiaMessagesController
    original_evidence_prompt = controller.instance_method(:attached_document_evidence_prompt)
    captured_evidence_prompts = []
    controller.define_method(:attached_document_evidence_prompt) do |content, result|
      prompt = original_evidence_prompt.bind_call(self, content, result)
      captured_evidence_prompts << prompt
      prompt
    end

    assert_no_difference([ "MiaActionDraft.count", "HouseholdTransaction.count", "BudgetYear.count", "BudgetAllocation.count" ]) do
      with_singleton_stub(HouseholdFinance::MiaIntentResolver, :new, nil_resolver) do
        post "/api/v1/mia/messages",
             params: { message: message, document_import_ids: [ document_import.id ] },
             headers: auth_headers(user),
             as: :json
      end
    end

    assert_response :created
    body = response.parsed_body
    assert_equal [ message ], captured_evidence_prompts
    assert_not_includes body.dig("assistant_message", "content"), "could not safely prepare"
    assert_not_includes body.dig("assistant_message", "content"), "Send the change as a new message"
    assert_nil body.fetch("mia_action_draft")
    assert_nil body.fetch("budget")
    assert_equal message, body.dig("user_message", "content")
    assert_equal document_import.id, body.dig("user_message", "attachments", 0, "document_import_id")

    session = household.chat_sessions.find_by!(user: user)
    evidence = session.reload.active_topic.fetch("document_evidence")
    assert_equal [ document_import.id ], evidence.fetch("financial_document_import_ids")
  ensure
    controller&.define_method(:attached_document_evidence_prompt, original_evidence_prompt) if original_evidence_prompt
  end

  def create_user(email:, first_name: nil, role: "participant")
    User.create!(
      clerk_id: "clerk_#{SecureRandom.hex(6)}",
      email: email,
      first_name: first_name,
      role: role,
      invitation_status: "accepted"
    )
  end

  def auth_headers(user)
    { "Authorization" => "Bearer test_token_#{user.id}" }
  end

  def confirm_setup_for_test(user)
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    household.update!(
      primary_goal: "Build a stable plan",
      confirmed_setup_fields: HouseholdFinance::SetupStatus::REQUIRED_FIELDS.map(&:to_s)
    )
    profile = household.household_profile
    summary_confirmed = profile.debt_tracking_mode == "summary" &&
      profile.debt_summary_balance_known? && profile.debt_summary_minimum_payment_known?
    unless household.debts.active.exists? || summary_confirmed
      profile.update!(
        debt_tracking_mode: "summary", debt_summary_balance_cents: 0,
        debt_summary_minimum_payment_cents: 0,
        debt_summary_balance_known: true, debt_summary_minimum_payment_known: true
      )
    end
  end

  def create_mia_attachment_import(household, user, key)
    household.financial_document_imports.create!(
      uploaded_by_user: user,
      document_kind: "receipt",
      status: "needs_review",
      filename: "#{key}.png",
      content_type: "image/png",
      byte_size: 128,
      s3_key: "household-cfo/test/#{key}-#{SecureRandom.hex(4)}.png"
    )
  end

  def create_mia_attachment_draft(document_import, household, category:, amount_cents:, occurred_on:)
    document_import.transaction_drafts.create!(
      household: household,
      occurred_on: occurred_on,
      merchant: document_import.filename.delete_suffix(".png").humanize,
      total_amount_cents: amount_cents,
      budget_category: category,
      source_type: "receipt",
      status: "pending",
      raw_input: "attachment plan-fit test"
    )
  end

  def set_mia_plan_allocation(budget_year, category, month:, cents:)
    period = budget_year.budget_periods.find_by!(starts_on: Date.new(budget_year.year, month, 1))
    BudgetAllocation.find_by!(budget_period: period, budget_category: category).update!(planned_amount_cents: cents)
  end

  def with_singleton_stub(target, method_name, replacement)
    singleton = class << target; self; end
    original = singleton.instance_method(method_name)
    singleton.define_method(method_name) do |*args, **kwargs, &block|
      replacement.call(*args, **kwargs, &block)
    end
    yield
  ensure
    singleton.send(:remove_method, method_name) if singleton.method_defined?(method_name)
    singleton.define_method(method_name, original)
  end
end
