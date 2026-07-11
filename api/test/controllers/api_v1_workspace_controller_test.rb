require "test_helper"

class ApiV1WorkspaceControllerTest < ActionDispatch::IntegrationTest
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
              credit_card_debt: 7_000,
              debt_payment: 700,
              target_runway_months: 6
            }
          },
          headers: auth_headers(user),
          as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "Mendiola Household", body.fetch("profile").fetch("household").fetch("name")
    assert_equal 9_200, body.fetch("dashboard").fetch("summary").fetch("monthly_income")
    assert_equal 7_300, body.fetch("budget").fetch("total_monthly_outflow")
    assert_equal 1_900, body.fetch("budget").fetch("baseline_surplus")
    assert_equal 2.5, body.fetch("dashboard").fetch("summary").fetch("runway_months")
  end

  test "workspace setup partial patch preserves omitted financial values" do
    user = create_user(email: "partial-setup@example.com")

    patch "/api/v1/workspace/setup",
          params: {
            workspace: {
              primary_income: 8_000,
              fixed_expenses: 4_500,
              emergency_fund: 18_000,
              credit_card_debt: 7_000,
              debt_payment: 700,
              target_runway_months: 12
            }
          },
          headers: auth_headers(user),
          as: :json
    patch "/api/v1/workspace/setup",
          params: { workspace: { household_name: "Renamed Household" } },
          headers: auth_headers(user),
          as: :json

    assert_response :success
    household = user.households.first
    assert_equal "Renamed Household", household.name
    assert_equal 800_000, household.income_sources.find_by!(source_type: "job").amount_cents
    assert_equal 450_000, household.expense_items.find_by!(stack_key: "non_discretionary").amount_cents
    assert_equal 1_800_000, household.accounts.find_by!(account_type: "emergency_fund").balance_cents
    assert_equal 700_000, household.debts.find_by!(debt_type: "credit_card").balance_cents
    assert_equal 12, household.goals.find_by!(goal_type: "runway").target_months

    patch "/api/v1/workspace/setup",
          params: { workspace: { debt_payment: 900 } },
          headers: auth_headers(user),
          as: :json

    assert_response :success
    debt = household.debts.find_by!(debt_type: "credit_card")
    assert_equal 700_000, debt.balance_cents
    assert_equal 90_000, debt.minimum_payment_cents
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

  test "workspace setup distributes aggregate income and expense edits across detailed rows" do
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

    assert_response :success
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
    assert_equal 600_000, household.income_sources.where(source_type: "job", active: true).sum(:amount_cents)
    assert_equal 200_000, household.expense_items.where(stack_key: "non_discretionary", active: true).sum(:amount_cents)
  end

  test "workspace setup updates document-derived debt payment instead of duplicating debt" do
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
    assert_equal 17_500, debt.minimum_payment_cents
  end

  test "workspace setup applies aggregate debt edits across multiple detailed debts" do
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
    assert_equal "Visa card", visa.reload.label
    assert_equal "Mastercard", mastercard.reload.label
    assert_equal 400_000, household.debts.where(debt_type: "credit_card").sum(:balance_cents)
    assert_equal 20_000, household.debts.where(debt_type: "credit_card").sum(:minimum_payment_cents)
    assert_operator visa.balance_cents, :<, 340_000
    assert_operator mastercard.balance_cents, :<, 120_000
  end

  test "workspace setup removes cleared credit card debt" do
    user = create_user(email: "clear-debt@example.com")

    patch "/api/v1/workspace/setup",
          params: { workspace: { credit_card_debt: 7_000, debt_payment: 700 } },
          headers: auth_headers(user),
          as: :json
    patch "/api/v1/workspace/setup",
          params: { workspace: { credit_card_debt: 0, debt_payment: 0 } },
          headers: auth_headers(user),
          as: :json

    assert_response :success
    household = user.households.first
    assert_empty household.debts.where(debt_type: "credit_card")
    savings_section = JSON.parse(response.body).fetch("profile").fetch("sections").find { |section| section.fetch("label") == "Savings & Debt" }
    assert savings_section.fetch("items").none? { |item| item.fetch("label") == "Credit card debt" }
  end

  test "workspace setup values keep other assets separate from typed accounts" do
    user = create_user(email: "assets@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    household.accounts.create!(label: "Emergency fund", account_type: "emergency_fund", balance_cents: 500_000)
    household.accounts.create!(label: "Other assets", account_type: "other", balance_cents: 1_200_000)
    household.accounts.create!(label: "Investment account", account_type: "investment", balance_cents: 3_000_000)

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
    assert body.fetch("errors").any? { |error| error.include?("Amount cents") }
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
    household.debts.create!(label: "Credit card debt", debt_type: "credit_card", balance_cents: 2_000_000)
    household.debts.create!(label: "Mortgage", debt_type: "mortgage", balance_cents: 50_000_000)

    get "/api/v1/workspace", headers: auth_headers(user)

    assert_response :success
    wealth = JSON.parse(response.body).fetch("wealth").fetch("summary")
    assert_equal(-420_000, wealth.fetch("net_worth"))
    assert_equal 80_000, wealth.fetch("liquid_net_worth")
  end

  test "mia chat uses real workspace context and persists messages" do
    user = create_user(email: "mia@example.com")
    patch "/api/v1/workspace/setup",
          params: { workspace: { primary_income: 8_000, fixed_expenses: 4_000, emergency_fund: 8_000 } },
          headers: auth_headers(user),
          as: :json

    post "/api/v1/mia/messages",
         params: { message: "Can I buy the purse?" },
         headers: auth_headers(user),
         as: :json

    assert_response :created
    content = JSON.parse(response.body).fetch("assistant_message").fetch("content")
    assert_includes content, "Lanya chelu"
    assert_includes content, "that purse isn’t in the cards right now"

    get "/api/v1/mia/messages", headers: auth_headers(user)

    assert_response :success
    messages = JSON.parse(response.body).fetch("messages")
    assert_equal [ "user", "assistant" ], messages.map { |message| message.fetch("role") }
  end

  test "mia chat routes deterministic coaching packets through Mia narrator" do
    user = create_user(email: "mia-narrator@example.com")
    patch "/api/v1/workspace/setup",
          params: { workspace: { primary_income: 8_000, fixed_expenses: 4_000, emergency_fund: 8_000 } },
          headers: auth_headers(user),
          as: :json
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
    assert_includes assistant_content, "3 pending transaction reviews"
    assert_includes assistant_content, "Jul 1, 2026 through Jul 3, 2026"
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
    assert_not_includes assistant_content, "I used your note as context"
    assert_includes assistant_content, "I found Resend for $20"
    attachment = body.fetch("user_message").fetch("attachments").first
    assert_equal document_import.id, attachment.fetch("document_import_id")
    assert_equal "receipt.png", attachment.fetch("filename")
    assert_equal "needs_review", attachment.fetch("status")

    get "/api/v1/mia/messages", headers: auth_headers(user)

    assert_response :success
    user_message = JSON.parse(response.body).fetch("messages").find { |message| message.fetch("role") == "user" }
    assert_equal document_import.id, user_message.fetch("attachments").first.fetch("document_import_id")
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

    post "/api/v1/mia/messages",
         params: { message: "Can you set up my budget from this?", document_import_ids: [ document_import.id ] },
         headers: auth_headers(user),
         as: :json

    assert_response :created
    assistant_content = JSON.parse(response.body).fetch("assistant_message").fetch("content")
    assert_not_includes assistant_content, "I used your note as context"
    assert_includes assistant_content, "budget/profile setup values"
    assert_includes assistant_content, "Main income and Groceries"
    assert_includes assistant_content, "open Review imports to approve or adjust"
  end

  test "mia chat compacts conversation continuity for follow-up questions" do
    user = create_user(email: "mia-continuity@example.com")
    patch "/api/v1/workspace/setup",
          params: {
            workspace: {
              primary_income: 8_000,
              fixed_expenses: 4_000,
              flexible_spend: 1_000,
              emergency_fund: 8_000,
              credit_card_debt: 2_000,
              debt_payment: 150
            }
          },
          headers: auth_headers(user),
          as: :json

    household = HouseholdFinance::WorkspaceResolver.new(user).household
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

  test "mia chat can resume compacted context across requests and clear it" do
    user = create_user(email: "mia-resume-context@example.com")
    patch "/api/v1/workspace/setup",
          params: { workspace: { primary_income: 8_000, fixed_expenses: 4_000, emergency_fund: 8_000 } },
          headers: auth_headers(user),
          as: :json

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

  test "mia chat rejects messages above the storage limit" do
    user = create_user(email: "long-mia@example.com")

    assert_no_difference("ChatMessage.count") do
      post "/api/v1/mia/messages",
           params: { message: "a" * (ChatMessage::MAX_CONTENT_LENGTH + 1) },
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
      Demo::MiaResponder.define_singleton_method(:new) { failing_responder }

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

  test "mia chat returns every persisted message since the last clear" do
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
  end

  test "mia chat history can be cleared" do
    user = create_user(email: "clear@example.com")
    post "/api/v1/mia/messages", params: { message: "test" }, headers: auth_headers(user), as: :json

    delete "/api/v1/mia/messages", headers: auth_headers(user)

    assert_response :no_content

    get "/api/v1/mia/messages", headers: auth_headers(user)

    assert_response :success
    assert_empty JSON.parse(response.body).fetch("messages")
  end

  test "clearing empty Mia chat does not create a chat session" do
    user = create_user(email: "no-session-clear@example.com")

    assert_no_difference("ChatSession.count") do
      delete "/api/v1/mia/messages", headers: auth_headers(user)
    end

    assert_response :no_content
  end

  private

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
