# frozen_string_literal: true

require "test_helper"

class ApiV1MonthlyCloseTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  test "requires authentication" do
    get "/api/v1/budget/monthly_close", params: { year: 2026, month: 10 }
    assert_response :unauthorized
  end

  test "returns monthly close for authenticated owner with zero DB writes even for an unmaterialized year" do
    user = create_user(email: "monthly-close-owner@example.invalid")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    household.update_column(:created_at, Time.zone.local(2026, 1, 5, 9, 0, 0))
    manager = HouseholdFinance::AnnualBudgetManager.new(household, year: 2026)
    groceries = manager.create_category!(name: "Groceries", stack_key: "non_discretionary", monthly_amount: 600)
    period = household.budget_years.find_by!(year: 2026).budget_periods.find_by!(starts_on: Date.new(2026, 10, 1))
    tx = household.household_transactions.create!(
      budget_period: period,
      occurred_on: Date.new(2026, 10, 8),
      merchant: "Payless",
      total_amount_cents: 45_000,
      status: "confirmed",
      source_type: "manual_ui"
    )
    tx.transaction_splits.create!(budget_category: groceries, amount_cents: 45_000)

    travel_to Time.zone.local(2026, 11, 5, 10, 0, 0) do
      assert_no_db_writes do
        get "/api/v1/budget/monthly_close", params: { year: 2026, month: 10 }, headers: auth_headers(user)
      end
      assert_response :success
      assert_equal household.financial_generation.to_s, response.headers["X-Financial-Generation"]

      body = response.parsed_body.fetch("monthly_close")
      assert_equal 2026, body["year"]
      assert_equal 10, body["month"]
      assert_equal "October 2026", body["period_label"]
      assert_equal 45_000, body.dig("totals", "actual_spending_cents")
      assert_equal 60_000, body.dig("totals", "planned_spending_cents")
      assert_equal(-15_000, body.dig("totals", "spending_difference_cents"))

      # Unmaterialized year 2028 must also perform zero writes!
      assert_no_db_writes do
        get "/api/v1/budget/monthly_close", params: { year: 2028, month: 3 }, headers: auth_headers(user)
      end
      assert_response :success
      future = response.parsed_body.fetch("monthly_close")
      assert_equal "future", future["status"]
      assert_equal false, future["plan_available"]
    end
  end

  test "defaults to current Guam year and month when params are omitted" do
    user = create_user(email: "monthly-close-default@example.invalid")
    HouseholdFinance::WorkspaceResolver.new(user).household

    # 2026-10-31 15:00 UTC is 2026-11-01 01:00 Pacific/Guam (+10)
    travel_to Time.utc(2026, 10, 31, 15, 0, 0) do
      get "/api/v1/budget/monthly_close", headers: auth_headers(user)
      assert_response :success
      body = response.parsed_body.fetch("monthly_close")
      assert_equal 2026, body["year"]
      assert_equal 11, body["month"]
      assert_equal "open", body["status"]
    end
  end

  test "rejects invalid year or month params with 422" do
    user = create_user(email: "monthly-close-invalid@example.invalid")
    HouseholdFinance::WorkspaceResolver.new(user).household

    [
      { year: 1999, month: 10 },
      { year: 2101, month: 10 },
      { year: "2026abc", month: 10 },
      { year: 2026, month: 0 },
      { year: 2026, month: 13 },
      { year: 2026, month: "oct" }
    ].each do |invalid_params|
      get "/api/v1/budget/monthly_close", params: invalid_params, headers: auth_headers(user)
      assert_response :unprocessable_entity, "Expected 422 for #{invalid_params.inspect}"
      assert response.parsed_body["errors"].present?
    end
  end

  test "blocks staff access to a pilot participant household via ChallengePrivacy" do
    participant = create_user(email: "pilot-close-participant@example.invalid", role: "participant")
    coach = create_user(email: "pilot-close-coach@example.invalid", role: "coach")
    cohort = Cohort.create!(name: "Pilot Savings", status: "active", savings_challenge_enabled: true, created_by_user: coach)
    cohort.cohort_memberships.create!(user: participant, role: "participant")
    household = HouseholdFinance::WorkspaceResolver.new(participant).household
    # Even if a staff user somehow had a membership on a pilot household, PrivateFinanceAccess denies it.
    household.household_memberships.create!(user: coach, role: "partner")

    get "/api/v1/budget/monthly_close", params: { year: 2026, month: 10 }, headers: auth_headers(coach)
    assert_response :forbidden
    assert_equal "private, no-store", response.headers["Cache-Control"]
  end

  test "respects cohort method group_names setting" do
    coach = create_user(email: "method-close-coach@example.invalid", role: "coach")
    participant = create_user(email: "method-close-participant@example.invalid", role: "participant")
    cohort = Cohort.create!(name: "Mrs Mel Terms", status: "active", created_by_user: coach)
    cohort.cohort_memberships.create!(user: participant, role: "participant")
    config = cohort.cohort_experience_configuration
    config.update!(
      draft_config: CohortExperience::Schema::DEFAULT_CONFIG.deep_merge("method" => { "group_names" => "method" }),
      last_edited_by_user: coach
    )
    publisher = CohortExperience::Publisher.new(configuration: config, actor: coach)
    digest = publisher.preview!(expected_draft_revision: config.draft_revision)
    publisher.publish!(expected_preview_digest: digest, expected_draft_revision: config.draft_revision, expected_current_version_id: nil)

    household = HouseholdFinance::WorkspaceResolver.new(participant).household
    HouseholdFinance::AnnualBudgetManager.new(household, year: 2026).create_category!(name: "Rent", stack_key: "non_discretionary", monthly_amount: 1_500)

    get "/api/v1/budget/monthly_close", params: { year: 2026, month: 10 }, headers: auth_headers(participant)
    assert_response :success
    rent = response.parsed_body.dig("monthly_close", "categories").find { |row| row["name"] == "Rent" }
    assert_equal "Non-discretionary", rent["stack_label"]
  end

  test "does not swallow unrelated internal ArgumentError from MonthlyClose#call as 422" do
    user = create_user(email: "monthly-close-internal-err@example.invalid")
    HouseholdFinance::WorkspaceResolver.new(user).household

    original_call = HouseholdFinance::MonthlyClose.instance_method(:call)
    HouseholdFinance::MonthlyClose.define_method(:call) { raise ArgumentError, "unexpected internal bug" }
    begin
      error = assert_raises(ArgumentError) do
        get "/api/v1/budget/monthly_close", params: { year: 2026, month: 10 }, headers: auth_headers(user)
      end
      assert_equal "unexpected internal bug", error.message
    ensure
      HouseholdFinance::MonthlyClose.define_method(:call, original_call)
    end
  end

  private

  def assert_no_db_writes(&block)
    writes = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      next if payload[:name] == "SCHEMA" || payload[:cached]

      sql = payload[:sql].to_s
      if sql.match?(/\A\s*(?:INSERT|UPDATE|DELETE|REPLACE|MERGE|TRUNCATE|CREATE|ALTER|DROP)\b/i)
        writes << sql
      end
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &block)
    assert_empty writes, "Expected zero database writes, but saw:\n#{writes.join("\n")}"
  end

  def create_user(email:, role: "participant")
    User.create!(clerk_id: "mc-#{SecureRandom.hex(8)}", email: email, role: role, invitation_status: "accepted")
  end

  def auth_headers(user)
    { "Authorization" => "Bearer test_token_#{user.id}" }
  end
end
