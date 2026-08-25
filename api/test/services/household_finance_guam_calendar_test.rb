require "test_helper"

class HouseholdFinanceGuamCalendarTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  test "the household financial calendar uses the Guam time zone" do
    assert_equal "Pacific/Guam", Time.zone.tzinfo.identifier
  end

  test "the local calendar advances before the UTC month does" do
    travel_to Time.utc(2026, 8, 31, 15, 0, 0) do
      assert_equal Date.new(2026, 9, 1), Date.current
      assert_equal "September", Demo::HouseholdData.dashboard.dig(:action_center, :current_month_label)
      assert_equal 8, Demo::HouseholdData.dashboard.dig(:action_center, :current_month_index)
    end
  end

  test "annual planning follows the Guam new year before UTC midnight" do
    travel_to Time.utc(2026, 12, 31, 15, 0, 0) do
      assert_equal Date.new(2027, 1, 1), Date.current
      assert_equal 2027, Demo::HouseholdData.annual_plan.fetch(:year)
      assert_equal 2027, Demo::HouseholdData.dashboard.dig(:action_center, :current_year)
    end
  end
end
