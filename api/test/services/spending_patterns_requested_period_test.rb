require "test_helper"

class SpendingPatternsRequestedPeriodTest < ActiveSupport::TestCase
  test "explicit calendar and relative periods honor Guam today rather than the newest record" do
    {
      "in January 2025" => [ "2025-01-01", "2025-01-31" ],
      "during Jan 2025" => [ "2025-01-01", "2025-01-31" ],
      "in September" => [ "2026-09-01", "2026-09-30" ],
      "this month" => [ "2026-11-01", "2026-11-02" ],
      "last month" => [ "2026-10-01", "2026-10-31" ],
      "in my last 3 months" => [ "2026-08-01", "2026-10-31" ],
      "over the last 12 months" => [ "2025-11-01", "2026-10-31" ],
      "in 2025" => [ "2025-01-01", "2025-12-31" ],
      "on 2025-01-05" => [ "2025-01-05", "2025-01-05" ],
      "from 2025-12-01 through 2026-01-31" => [ "2025-12-01", "2026-01-31" ]
    }.each do |suffix, expected|
      result = resolve("What spending patterns do you see #{suffix}?")
      assert_equal expected, result.values_at(:from, :to).map(&:iso8601), suffix
    end
    assert_empty resolve("What spending patterns do you see?")
  end

  test "unsupported invalid ambiguous and future periods never fall back to the default window" do
    [ "in Q1", "in Q1 2025", "in summer 2025", "in summer", "in the first half of 2025", "in early January 2025", "before January 2025", "after January 2025", "until January 2025", "next January 2025", "last summer", "last week", "last year", "since January 2025", "between January 2025 and March 2025", "in January 2025 through March 2025",
      "in January and March 2025", "last 0 months", "last 13 months", "in January 2027", "on 2026-02-30", "from 2026-02-01 to 2026-01-01" ].each do |suffix|
      assert_raises(SpendingPatterns::RequestedPeriod::Unsupported, suffix) { resolve("What spending patterns do you see #{suffix}?") }
    end
  end

  private

  def resolve(message)
    SpendingPatterns::RequestedPeriod.new(message, today: Date.new(2026, 11, 2)).call
  end
end
