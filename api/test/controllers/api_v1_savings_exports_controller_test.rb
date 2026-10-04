require "test_helper"
require_relative "../support/savings_debt_test_support"

class ApiV1SavingsExportsControllerTest < ActionDispatch::IntegrationTest
  include SavingsDebtTestSupport
  setup do
    travel_to Time.find_zone!("Pacific/Guam").local(2026, 11, 1, 12)
    setup_savings_context
    @daily_category = @savings_household.budget_categories.create!(name: "Synthetic food", stack_key: "discretionary", sort_order: 1)
    with_daily_operations do
      savings_enroll
      savings_plan
      entry = savings_approve(savings_draft(10_000)).savings_entry
      savings_approve(savings_draft(12_000, entry: entry))
      savings_approve(savings_draft(-2_000, funding: "withdrawal"))
      savings_draft(99_999)
      purchase = daily_approve(daily_stage).subject.savings_daily_purchase
      @reflection = daily_reflection(purchase).subject
      daily_check_in("spending")
    end
  end
  teardown { travel_back }

  test "own atomic export keeps approved corrections separate and excludes feelings by default" do
    get path, params: { include_reflections: "false" }, headers: auth(@savings_user).merge("Content-Type" => "application/json")
    assert_response :success
    result = response.parsed_body
    assert_equal 10_000, result.dig("projection", "reported_cents")
    assert_equal [ 10_000, 12_000, -2_000 ], result.dig("savings", "entry_versions").pluck("signed_cents")
    assert_equal 2, result["current_entries"].length
    assert_not result["daily"].key?("reflection_versions")
    assert_not response.body.match?(/Hopeful|Calm|99_999|99999|s3_key|clerk_id|email/)
    assert_includes response.headers["Cache-Control"], "no-store"
    get path, params: { include_reflections: "true" }, headers: auth(@savings_user)
    assert_response :success
    assert_equal "Hopeful", response.parsed_body.dig("daily", "reflection_versions").sole["feeling_then"]
    with_daily_operations { daily_erase(@reflection) }
    get path, params: { include_reflections: "true" }, headers: auth(@savings_user)
    assert_response :success
    assert_not response.body.match?(/Hopeful|Calm/)
    assert_not response.parsed_body.dig("daily", "reflection_versions").empty?
  end

  test "export rejects another actor unsupported filters and unavailable runtime" do
    get path, headers: auth(@savings_user)
    assert_response :unprocessable_entity
    get path, params: { include_reflections: "false", enrollment_id: @savings_enrollment.id }, headers: auth(@savings_user)
    assert_response :unprocessable_entity
    get path, params: { include_reflections: "false" }, headers: auth(@savings_owner)
    assert_response :forbidden
    @savings_cohort.update!(savings_challenge_release_hold: true)
    get path, params: { include_reflections: "false" }, headers: auth(@savings_user)
    assert_response :forbidden
    assert_not response.body.match?(/12000|Hopeful|entry_versions/)
  end

  test "private export includes only approved optional debt heads and immutable terms history" do
    with_savings_runtime do
      first = debt_approve(debt_stage)
      debt_approve(debt_stage(debt_terms(balance_cents: 25_000), card: first.savings_debt_card))
      debt_stage(debt_terms(label: "Pending private card"))
    end
    get path, params: { include_reflections: "false" }, headers: auth(@savings_user)
    assert_response :success
    result = response.parsed_body
    assert_equal [ 30_000, 25_000 ], result.dig("savings", "debt_versions").map { |row| row.dig("terms", "balance_cents") }
    assert_equal 1, result["current_debt_cards"].length
    refute_includes response.body, "Pending private card"
    assert_equal 10_000, result.dig("projection", "reported_cents")
  end

  private
  def auth(user) = { "Authorization" => "Bearer test_token_#{user.id}" }
  def path = "/api/v1/savings_challenge/export"
end
