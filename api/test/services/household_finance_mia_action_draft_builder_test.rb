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
    assert_equal "update_category", rename_result.proposal.items.first.action_type
    assert_equal "Household Groceries", rename_result.proposal.items.first.payload.fetch(:name)
    assert_equal "non_discretionary", reclassify_result.proposal.items.first.payload.fetch(:stack_key)
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
