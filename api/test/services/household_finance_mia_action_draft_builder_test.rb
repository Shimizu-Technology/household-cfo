require "test_helper"

class HouseholdFinanceMiaActionDraftBuilderTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(clerk_id: "clerk_#{SecureRandom.hex(6)}", email: "action-builder-#{SecureRandom.hex(4)}@example.com", role: "participant", invitation_status: "accepted")
    @household = Household.create!(created_by_user: @user, name: "Action Builder Household")
    @household.household_memberships.create!(user: @user, role: "owner")
    @manager = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026)
    @groceries = @manager.create_category!(name: "Groceries", stack_key: "discretionary", monthly_amount: 500)
    @dining = @manager.create_category!(name: "Dining Out", stack_key: "discretionary", monthly_amount: 300)
  end

  test "builds structured allocation and move proposals without parsing natural language" do
    allocation = build_command(
      type: "set_allocation",
      category_id: @groceries.id,
      category_name: "Groceries",
      amount: "650",
      months: [ 7 ],
      year: 2026
    )
    move = build_command(
      type: "move_allocation",
      category_id: @dining.id,
      category_name: "Dining Out",
      target_category_id: @groceries.id,
      target_category_name: "Groceries",
      amount: "50",
      months: [ 8 ],
      year: 2026
    )

    assert allocation.proposal
    allocation_change = allocation.proposal.items.first.payload.fetch(:changes).first
    assert_equal 7, allocation_change.fetch(:month)
    assert_equal 50_000, allocation_change.fetch(:before_cents)
    assert_equal 65_000, allocation_change.fetch(:after_cents)
    assert_equal 2, move.proposal.items.length
    assert_equal %w[update_allocation update_allocation], move.proposal.items.map(&:action_type)
  end

  test "builds structured category create rename and reclassify proposals" do
    create_result = build_command(
      type: "create_category",
      new_name: "School Supplies",
      stack_key: "sinking_expected",
      amount: "75",
      months: (1..12).to_a,
      year: 2026
    )
    rename_result = build_command(
      type: "rename_category",
      category_id: @groceries.id,
      category_name: "Groceries",
      new_name: "Household Groceries",
      year: 2026
    )
    reclassify_result = build_command(
      type: "reclassify_category",
      category_id: @groceries.id,
      category_name: "Groceries",
      stack_key: "non_discretionary",
      year: 2026
    )

    assert_equal "create_category", create_result.proposal.items.first.action_type
    assert_equal "sinking_expected", create_result.proposal.items.first.payload.fetch(:stack_key)
    assert_equal (1..12).to_a, create_result.proposal.items.first.payload.fetch(:month_numbers)
    assert_equal "update_category", rename_result.proposal.items.first.action_type
    assert_equal "Household Groceries", rename_result.proposal.items.first.payload.fetch(:name)
    assert_equal "non_discretionary", reclassify_result.proposal.items.first.payload.fetch(:stack_key)
  end

  test "preserves a single-month scope when creating a category" do
    result = build_command(
      type: "create_category",
      new_name: "School Supplies",
      stack_key: "sinking_expected",
      amount: "75",
      months: [ 8 ],
      year: 2026
    )

    item = result.proposal.items.first
    assert_equal [ 8 ], item.payload.fetch(:month_numbers)
    assert_includes item.label, "Aug 2026"
    refute_includes item.description, "every month"
  end

  test "asks for month scope instead of widening a structured category amount" do
    result = build_command(
      type: "create_category",
      new_name: "School Supplies",
      stack_key: "sinking_expected",
      amount: "75",
      months: [],
      year: 2026
    )

    assert_nil result.proposal
    assert_includes result.response, "every month, or only specific months"
  end

  test "explains that an archived category must be restored instead of edited" do
    @manager.archive_category!(@dining)

    structured = build_command(
      type: "create_category",
      new_name: "Dining Out",
      stack_key: "discretionary",
      amount: "75",
      months: [ 8 ],
      year: 2026
    )
    fallback = HouseholdFinance::MiaActionDraftBuilder.new(
      @household,
      "Create a budget category called Dining Out with $75 for August 2026",
      user: @user,
      annual_budget_manager: @manager,
      selected_month: 8,
      raw_input: "Create a budget category called Dining Out with $75 for August 2026"
    ).call

    [ structured, fallback ].each do |result|
      assert_nil result.proposal
      assert_includes result.response, "Dining Out is archived"
      assert_includes result.response, "Restore it"
    end
  end

  test "legacy category parser keeps an explicit month out of the category name" do
    result = HouseholdFinance::MiaActionDraftBuilder.new(
      @household,
      "Create a new sinking expected category called School Supplies with $75 for August 2026",
      user: @user,
      annual_budget_manager: @manager,
      selected_month: 8,
      raw_input: "Create a new sinking expected category called School Supplies with $75 for August 2026"
    ).call

    item = result.proposal.items.first
    assert_equal "School Supplies", item.payload.fetch(:name)
    assert_equal [ 8 ], item.payload.fetch(:month_numbers)
  end

  test "builds structured category archive and restore proposals in the correct scope" do
    archive_result = build_command(
      type: "archive_category",
      category_id: @dining.id,
      category_name: "Dining Out",
      year: 2026
    )
    @manager.archive_category!(@dining)
    restore_result = build_command(
      type: "restore_category",
      category_id: @dining.id,
      category_name: "Dining Out",
      year: 2026
    )

    assert_equal "archive_category", archive_result.proposal.items.first.action_type
    assert_equal "restore_category", restore_result.proposal.items.first.action_type
  end

  test "legacy fallback rejects calendar-relative months that cross the budget year" do
    next_month = move_next_month = nil
    travel_to Date.new(2026, 12, 15) do
      next_month = HouseholdFinance::MiaActionDraftBuilder.new(
        @household,
        "Set Groceries budget to $600 next month",
        user: @user,
        annual_budget_manager: @manager,
        selected_month: 1,
        raw_input: "Set Groceries budget to $600 next month"
      ).call
      move_next_month = HouseholdFinance::MiaActionDraftBuilder.new(
        @household,
        "Move $50 from Dining Out to Groceries in next month",
        user: @user,
        annual_budget_manager: @manager,
        selected_month: 1,
        raw_input: "Move $50 from Dining Out to Groceries in next month"
      ).call
    end

    last_month = nil
    travel_to Date.new(2026, 1, 15) do
      last_month = HouseholdFinance::MiaActionDraftBuilder.new(
        @household,
        "Set Groceries budget to $600 last month",
        user: @user,
        annual_budget_manager: @manager,
        selected_month: 12,
        raw_input: "Set Groceries budget to $600 last month"
      ).call
    end

    assert_nil next_month.proposal
    assert_includes next_month.response, "Next month falls outside the 2026 budget"
    assert_includes next_month.response, "Open 2027"
    assert_nil last_month.proposal
    assert_includes last_month.response, "Last month falls outside the 2026 budget"
    assert_includes last_month.response, "Open 2025"
    assert_nil move_next_month.proposal
    assert_includes move_next_month.response, "Next month falls outside the 2026 budget"
  end

  test "legacy relative month parsing ignores the month open in the budget UI" do
    travel_to Date.new(2026, 7, 10) do
      last_month = HouseholdFinance::MiaActionDraftBuilder.new(
        @household,
        "Set Groceries budget to $600 last month",
        user: @user,
        annual_budget_manager: @manager,
        selected_month: 1,
        raw_input: "Set Groceries budget to $600 last month"
      ).call
      next_month = HouseholdFinance::MiaActionDraftBuilder.new(
        @household,
        "Set Groceries budget to $650 next month",
        user: @user,
        annual_budget_manager: @manager,
        selected_month: 12,
        raw_input: "Set Groceries budget to $650 next month"
      ).call

      assert_equal [ 6 ], last_month.proposal.items.first.payload.fetch(:changes).pluck(:month)
      assert_equal [ 8 ], next_month.proposal.items.first.payload.fetch(:changes).pluck(:month)
    end
  end

  test "rejects structured no-op wrong-year and unknown-category commands" do
    no_op = build_command(
      type: "set_allocation",
      category_id: @groceries.id,
      category_name: "Groceries",
      amount: "500",
      months: [ 7 ],
      year: 2026
    )
    wrong_year = build_command(
      type: "set_allocation",
      category_id: @groceries.id,
      category_name: "Groceries",
      amount: "600",
      months: [ 7 ],
      year: 2027
    )
    unknown = build_command(
      type: "set_allocation",
      category_id: 999_999,
      category_name: "Invented Category",
      amount: "600",
      months: [ 7 ],
      year: 2026
    )

    assert_nil no_op.proposal
    assert_includes no_op.response, "nothing would change"
    assert_nil wrong_year.proposal
    assert_includes wrong_year.response, "working in 2026"
    assert_nil unknown.proposal
    assert_includes unknown.response, "active budget category"
  end

  private

  def build_command(command)
    HouseholdFinance::MiaActionDraftBuilder.new(
      @household,
      user: @user,
      annual_budget_manager: @manager,
      selected_month: 7,
      raw_input: "model resolved command",
      command: command
    ).call
  end
end
