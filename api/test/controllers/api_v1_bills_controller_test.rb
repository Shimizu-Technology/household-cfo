require "test_helper"

class ApiV1BillsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(clerk_id: "talun-bill-owner", email: "talun-bills@example.invalid", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    @headers = { "Authorization" => "Bearer test_token_#{@user.id}" }
  end

  test "participant explicitly creates edits and removes a bill" do
    post "/api/v1/bills", params: { bill: { name: "Talun fee", amount: "12.34", due_on: "2026-12-31", repeat_months: 12, must_pay: true } }, headers: @headers, as: :json
    assert_response :created
    bill = @household.bills.sole
    assert_equal 1234, bill.amount_cents
    patch "/api/v1/bills/#{bill.id}", params: { bill: { amount: "50", estimate: true } }, headers: @headers, as: :json
    assert_response :success
    assert_equal 5000, bill.reload.amount_cents
    assert bill.estimate?
    delete "/api/v1/bills/#{bill.id}", headers: @headers
    assert_response :success
    assert_empty @household.bills
    events = @household.household_audit_events.where(auditable_type: "Bill").order(:id)
    assert_equal %w[bill.created bill.updated bill.removed], events.map(&:event_type)
    assert_equal [ [ nil, 1234 ], [ 1234, 5000 ], [ 5000, nil ] ], events.map { |event| event.metadata.values_at("amount_cents_before", "amount_cents_after") }
  end

  test "only a one time bill is marked paid, by her, and audited" do
    post "/api/v1/bills", params: { bill: { name: "Talun repair", amount: "690", due_on: "2026-09-22" } }, headers: @headers, as: :json
    bill = @household.bills.sole
    post "/api/v1/bills/#{bill.id}/paid", params: { paid: true }, headers: @headers, as: :json
    assert_response :success
    assert_equal Date.current, bill.reload.paid_on
    assert_equal "bill.paid", @household.household_audit_events.order(:id).last.event_type
    post "/api/v1/bills/#{bill.id}/paid", params: { paid: false }, headers: @headers, as: :json
    assert_nil bill.reload.paid_on
    assert_equal "bill.unpaid", @household.household_audit_events.order(:id).last.event_type

    bill.update!(repeat_months: 1)
    assert_no_difference -> { @household.household_audit_events.count } do
      post "/api/v1/bills/#{bill.id}/paid", params: { paid: true }, headers: @headers, as: :json
    end
    assert_response :unprocessable_entity
    assert_nil bill.reload.paid_on
  end

  test "the workspace says whether she can change bills" do
    get "/api/v1/workspace", headers: @headers
    assert_response :success
    assert_equal true, response.parsed_body.dig("workspace", "can_edit_household")
  end

  test "reject another household category and invalid amounts" do
    other = Household.create!(name: "Invented neighbor", created_by_user: @user)
    category = other.budget_categories.create!(name: "Private fee", stack_key: "discretionary")
    assert_no_difference "Bill.count" do
      post "/api/v1/bills", params: { bill: { name: "Talun fee", amount: 50, due_on: "2026-12-20", budget_category_id: category.id } }, headers: @headers, as: :json
    end
    assert_response :unprocessable_entity
    post "/api/v1/bills", params: { bill: { name: "Talun fee", amount: -1, due_on: "2026-12-20" } }, headers: @headers, as: :json
    assert_response :unprocessable_entity
  end

  test "a retried save with the same key returns the bill it already saved" do
    headers = @headers.merge("Idempotency-Key" => "talun-bill-save-1")
    body = { bill: { name: "Talun water", amount: "40", due_on: "2026-12-05" } }
    post "/api/v1/bills", params: body, headers: headers, as: :json
    assert_response :created
    first = response.parsed_body["bill_id"]
    assert_no_difference [ "Bill.count", -> { @household.household_audit_events.count } ] do
      post "/api/v1/bills", params: body, headers: headers, as: :json
    end
    assert_response :created
    assert_equal first, response.parsed_body["bill_id"]
    assert response.parsed_body["replayed"]
    post "/api/v1/bills", params: body, headers: @headers.merge("Idempotency-Key" => "talun-bill-save-2"), as: :json
    assert_equal 2, @household.bills.count
  end

  test "a category id that is not in her current plan is a clear 422, not a database error" do
    missing = BudgetCategory.maximum(:id).to_i + 1_000
    assert_no_difference [ "Bill.count", -> { @household.household_audit_events.count } ] do
      post "/api/v1/bills", params: { bill: { name: "Talun fee", amount: 50, due_on: "2026-12-20", budget_category_id: missing } }, headers: @headers, as: :json
    end
    assert_response :unprocessable_entity
    assert_includes response.parsed_body["errors"].join, "active category in your current plan"

    bill = @household.bills.create!(name: "Talun power", amount_cents: 8_000, due_on: "2026-12-28", repeat_months: 1)
    patch "/api/v1/bills/#{bill.id}", params: { bill: { budget_category_id: missing } }, headers: @headers, as: :json
    assert_response :unprocessable_entity
    assert_includes response.parsed_body["errors"].join, "active category in your current plan"
    assert_nil bill.reload.budget_category_id
  end

  test "a replayed save key with edited values is refused instead of dropping the edits" do
    headers = @headers.merge("Idempotency-Key" => "talun-bill-edit-replay")
    post "/api/v1/bills", params: { bill: { name: "Talun water", amount: "40", due_on: "2026-12-05", repeat_months: "", must_pay: false } }, headers: headers, as: :json
    assert_response :created
    bill = Bill.find(response.parsed_body["bill_id"])
    assert_no_difference [ "Bill.count", -> { @household.household_audit_events.count } ] do
      post "/api/v1/bills", params: { bill: { name: "Talun water", amount: "40.00", due_on: "2026-12-05", repeat_months: "", must_pay: "false" } }, headers: headers, as: :json
      assert_response :created
      assert response.parsed_body["replayed"]
      post "/api/v1/bills", params: { bill: { name: "Talun water", amount: "55", due_on: "2026-12-09" } }, headers: headers, as: :json
    end
    assert_response :conflict
    assert_includes response.parsed_body["errors"].join, "already saved"
    assert_equal bill.id, response.parsed_body["bill_id"]
    assert_equal [ 4_000, Date.new(2026, 12, 5) ], bill.reload.values_at(:amount_cents, :due_on)
  end

  test "marking a bill paid whose category was archived explains why instead of failing" do
    category = @household.budget_categories.create!(name: "Talun repairs", stack_key: "discretionary")
    bill = @household.bills.create!(name: "Talun roof", amount_cents: 9_000, due_on: Date.new(2026, 9, 1), budget_category: category)
    category.update!(active: false)
    assert_no_difference -> { @household.household_audit_events.count } do
      post "/api/v1/bills/#{bill.id}/paid", params: { paid: true }, headers: @headers, as: :json
    end
    assert_response :unprocessable_entity
    assert_match(/active category/, response.parsed_body["errors"].join)
    assert_nil bill.reload.paid_on
  end

  test "a bill write from a superseded financial picture is rejected by the database guard" do
    bill = @household.bills.create!(name: "Talun phone", amount_cents: 6_000, due_on: Date.new(2026, 12, 9))
    @household.update_columns(financial_generation: @household.financial_generation + 1)
    error = assert_raises(ActiveRecord::StatementInvalid) { bill.update_columns(amount_cents: 1) }
    assert_match(/financial_generation_stale/, error.message)
    assert_raises(ActiveRecord::StatementInvalid) do
      Bill.insert_all!([ { household_id: @household.id, financial_generation: bill.financial_generation, name: "Stale", amount_cents: 1, due_on: Date.new(2026, 12, 1), created_at: Time.current, updated_at: Time.current } ])
    end
  end

  # Runs a change just before the controller takes the household lock: the gap between loading a bill and locking.
  module BeforeLock
    mattr_accessor :hook
    def with_lock(*args, &block)
      BeforeLock.hook&.call.tap { BeforeLock.hook = nil }
      super
    end
  end
  Household.prepend(BeforeLock) unless Household.ancestors.include?(BeforeLock)

  test "an edit audits the amount committed before it, not the one read before the lock" do
    bill = @household.bills.create!(name: "Talun power", amount_cents: 10_000, due_on: Date.new(2026, 12, 15))
    BeforeLock.hook = -> { Bill.where(id: bill.id).update_all(amount_cents: 12_000) }
    patch "/api/v1/bills/#{bill.id}", params: { bill: { name: "Talun power and light" } }, headers: @headers, as: :json
    assert_response :success
    event = @household.household_audit_events.where(event_type: "bill.updated").sole
    assert_equal [ 12_000, 12_000 ], event.metadata.values_at("amount_cents_before", "amount_cents_after")
  ensure
    BeforeLock.hook = nil
  end

  # Talun Telecom is $951.70 behind: owed now, separate from the monthly $120.
  test "a bill's past-due amount saves, clears back to not entered, and is audited" do
    post "/api/v1/bills", params: { bill: { name: "Talun Telecom", amount: "120", due_on: "2026-12-12", repeat_months: 1, past_due: "951.70" } },
      headers: @headers.merge("Idempotency-Key" => "talun-telecom"), as: :json
    assert_response :created
    bill = @household.bills.sole
    assert_equal 95_170, bill.past_due_cents
    forecast_bill = HouseholdFinance::AnnualBudgetManager.new(@household).read_only_plan_data.fetch(:year_forecast).fetch(:bills).sole
    assert_equal 95_170, forecast_bill.fetch(:past_due_cents)

    patch "/api/v1/bills/#{bill.id}", params: { bill: { past_due: "0" } }, headers: @headers, as: :json
    assert_equal 0, bill.reload.past_due_cents, "0 is caught up"
    patch "/api/v1/bills/#{bill.id}", params: { bill: { past_due: "" } }, headers: @headers, as: :json
    assert_nil bill.reload.past_due_cents, "blank is not entered, never $0"
    patch "/api/v1/bills/#{bill.id}", params: { bill: { amount: "125" } }, headers: @headers, as: :json
    assert_nil bill.reload.past_due_cents, "an edit that leaves it out keeps it"

    patch "/api/v1/bills/#{bill.id}", params: { bill: { past_due: "-5" } }, headers: @headers, as: :json
    assert_response :unprocessable_entity
    events = @household.household_audit_events.where(auditable_type: "Bill").order(:id)
    assert_equal [ [ nil, 95_170 ], [ 95_170, 0 ], [ 0, nil ], [ nil, nil ] ], events.map { |event| event.metadata.values_at("past_due_cents_before", "past_due_cents_after") }
    assert_raises(ActiveRecord::StatementInvalid) { Bill.transaction(requires_new: true) { bill.update_columns(past_due_cents: -1) } }
  end

  test "a replayed save key with a different past-due amount is refused, not dropped" do
    params = { bill: { name: "Talun Power", amount: "80", due_on: "2026-12-20", repeat_months: 1, past_due: "200" } }
    post "/api/v1/bills", params: params, headers: @headers.merge("Idempotency-Key" => "talun-power"), as: :json
    assert_response :created
    post "/api/v1/bills", params: params, headers: @headers.merge("Idempotency-Key" => "talun-power"), as: :json
    assert_equal true, response.parsed_body["replayed"]
    post "/api/v1/bills", params: { bill: params[:bill].merge(past_due: "250") }, headers: @headers.merge("Idempotency-Key" => "talun-power"), as: :json
    assert_response :conflict
    assert_equal 20_000, @household.bills.sole.past_due_cents
  end
end
