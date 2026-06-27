require "test_helper"

class HouseholdFinanceDataPresenterTest < ActiveSupport::TestCase
  test "blank workspace does not invent debt or CFO filter amounts" do
    user = User.create!(
      clerk_id: "clerk_#{SecureRandom.hex(6)}",
      email: "#{SecureRandom.hex(6)}@example.com",
      role: "participant",
      invitation_status: "accepted"
    )
    household = Household.create!(
      created_by_user: user,
      name: "Blank household",
      primary_goal: "Build a clear monthly money rhythm."
    )
    household.household_memberships.create!(user: user, role: "owner")

    payload = HouseholdFinance::DataPresenter.new(household, user: user).app_data
    debt_milestone = payload.dig(:wealth, :milestones).find { |milestone| milestone.fetch(:label) == "Debt entered" }
    decisions = payload.dig(:cfoFilter, :decisions)

    assert_equal 0, debt_milestone.fetch(:current)
    assert_equal 0, debt_milestone.fetch(:target)
    assert_equal "dollars entered", debt_milestone.fetch(:unit)
    assert_equal [ 0, 0, 0 ], decisions.map { |decision| decision.fetch(:amount) }
    assert_equal [ "Wait", "Wait", "Wait" ], decisions.map { |decision| decision.fetch(:recommendation) }
  end
end
