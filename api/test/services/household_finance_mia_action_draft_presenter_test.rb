require "test_helper"

class HouseholdFinanceMiaActionDraftPresenterTest < ActiveSupport::TestCase
  setup do
    travel_to Time.zone.local(2026, 11, 2, 12)
    @user = User.create!(clerk_id: "headline-#{SecureRandom.hex(6)}", email: "headline-#{SecureRandom.hex(6)}@example.invalid", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    @manager = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026)
    @dining = @manager.create_category!(name: "Dining out", stack_key: "discretionary", monthly_amount: 250)
    @repairs = @manager.create_category!(name: "Repairs & surprises", stack_key: "sinking_unexpected", monthly_amount: 40)
    @session = @household.chat_sessions.create!(user: @user, title: "Ask Mia")
  end

  teardown { travel_back }

  test "structured and legacy moves show the amount moved independently of prose and destination totals" do
    command = { type: "move_allocation", category_id: @dining.id, target_category_id: @repairs.id, amount: "60", months: [ 11 ], year: 2026 }
    [ command, nil ].each do |input|
      draft = build(input, message: "Move $60 from Dining out to Repairs & surprises for November")
      assert_includes draft.summary, "for November."
      refute_includes draft.summary, "per month"
      draft.update!(summary: "An unrelated $190 in prose must not become the figure")
      payload = present(draft)
      assert_equal({ amount_cents: 6000, label: "moved to Repairs & surprises" }, payload[:headline])
      assert_equal [ { label: "Dining out", before: "$250", after: "$190" }, { label: "Repairs & surprises", before: "$40", after: "$100" } ], payload[:detail_rows]
      assert_equal "November only. Your actual spending doesn’t change.", payload[:detail_note]
    end
  end

  test "a legacy move with an unknown starting amount has no invented figure" do
    draft = build(type: "move_allocation", category_id: @dining.id, target_category_id: @repairs.id, amount: "60", months: [ 11 ], year: 2026)
    item = draft.mia_action_items.first
    payload = item.payload.deep_dup
    payload["changes"].first["before_cents"] = nil
    item.update!(payload: payload)
    draft.mia_action_items.reset
    presented = present(draft)
    assert_nil presented[:headline]
    assert_equal "Not entered", presented[:detail_rows].first[:before]
  end

  test "allocation and category creation headline their planned amount and keep meaningful cents" do
    allocation = present(build(type: "set_allocation", category_id: @dining.id, amount: "190.25", months: [ 11 ], year: 2026))
    assert_equal({ amount_cents: 19_025, label: "new planned amount" }, allocation[:headline])
    assert_equal "$190.25", allocation[:detail_rows].sole[:after]
    category = present(build(type: "create_category", new_name: "School", amount: "30", stack_key: "discretionary", months: [ 11 ], year: 2026))
    assert_equal({ amount_cents: 3000, label: "new planned amount" }, category[:headline])
  end

  test "rename reclassify archive and restore do not invent a monetary figure" do
    [ { type: "rename_category", new_name: "Meals out" }, { type: "reclassify_category", stack_key: "non_discretionary" }, { type: "archive_category" } ].each do |command|
      assert_nil present(build(command.merge(category_id: @dining.id)))[:headline], command.inspect
    end
    @dining.update!(active: false)
    assert_nil present(build(type: "restore_category", category_id: @dining.id))[:headline]
  end

  test "salary and income schedules use new recurring or one-time amounts" do
    source = @household.income_sources.create!(label: "Salary", source_type: "job", amount_cents: 400_000, cadence: "monthly", starts_on: Date.new(2026, 1, 1))
    [ [ "recurring_change", "new monthly income" ], [ "one_time", "one-time income" ] ].each do |type, label|
      draft = build(type: "schedule_income_change", income_source_id: source.id, entry_type: type, amount: "4800", effective_on: "2026-11-01")
      assert_includes draft.summary, "November"
      refute_includes draft.summary, "November 2026"
      assert_equal({ amount_cents: 480_000, label: label }, present(draft)[:headline])
    end
    setup = present(build(type: "update_household_setup", setup_updates: { primary_income: "6500" }))
    assert_equal({ amount_cents: 650_000, label: "new monthly income" }, setup[:headline])
    created = present(build(type: "create_income_source", income_source_name: "Weekend work", source_type: "job", amount: "200", cadence: "weekly", effective_on: "2026-11-01"))
    assert_equal HouseholdFinance::Money.period_cents(20_000, "weekly", month: 11), created.dig(:headline, :amount_cents)
  end

  test "debt goal and account headlines preserve known amounts and omit unknowns" do
    debt = present(build(type: "create_debt", debt_name: "Visa", debt_type: "credit_card", balance: "3100", minimum_payment: "175"))
    assert_equal({ amount_cents: 310_000, label: "debt balance" }, debt[:headline])
    goal = present(build(type: "create_goal", goal_name: "Family trip", goal_type: "travel", target_amount: "5000", current_amount: "unknown"))
    assert_equal({ amount_cents: 500_000, label: "goal target" }, goal[:headline])
    unknown = present(build(type: "create_goal", goal_name: "Tuition", goal_type: "education", target_amount: "unknown", current_amount: "unknown"))
    assert_nil unknown[:headline]
    account = present(build(type: "create_account", account_name: "Emergency reserve", account_type: "savings", amount: "0"))
    assert_equal({ amount_cents: 0, label: "account balance" }, account[:headline])
  end

  test "noncurrent years remain explicit in budget and income sentences" do
    travel_to Time.zone.local(2027, 1, 2, 12)
    draft = build(type: "set_allocation", category_id: @dining.id, amount: "190", months: [ 11 ], year: 2026)
    assert_includes draft.summary, "November 2026"
    assert_includes present(draft)[:detail_note], "November 2026"
  end

  test "collection preloads provenance and resolves retained cohort IDs in one query" do
    coach = User.create!(clerk_id: "headline-coach-#{SecureRandom.hex(6)}", email: "headline-coach-#{SecureRandom.hex(6)}@example.invalid", role: "coach", invitation_status: "accepted")
    cohort = Cohort.create!(created_by_user: coach, name: "Synthetic challenge", status: "active", savings_challenge_enabled: true)
    drafts = 6.times.map do |index|
      build(type: "set_allocation", category_id: @dining.id, amount: "190", months: [ 11 ], year: 2026).tap do |draft|
        draft.update!(metadata: { review_program_scope: { cohort_id: cohort.id } })
        draft.update!(source_chat_message: nil, assistant_chat_message: nil) if index < 2
      end
    end
    queries = []
    subscriber = ->(_name, _start, _finish, _id, event) { queries << event[:sql] if event[:sql].match?(/SELECT.*FROM "(?:cohorts|chat_messages|chat_sessions)"/) }
    payloads = ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      HouseholdFinance::MiaActionDraftPresenter.collection(MiaActionDraft.where(id: drafts.map(&:id)))
    end
    assert_equal 1, queries.count { |query| query.include?('FROM "cohorts"') }, queries.inspect
    assert_operator queries.count { |query| query.include?('FROM "chat_messages"') }, :<=, 2, queries.inspect
    assert_operator queries.count { |query| query.include?('FROM "chat_sessions"') }, :<=, 2, queries.inspect
    assert payloads.all? { |payload| payload[:scope_note].include?("do not approve challenge savings") }
  end

  private

  def build(command = nil, message: "Prepare this change", **keywords)
    command ||= keywords.presence
    result = HouseholdFinance::MiaActionDraftBuilder.new(@household, message, user: @user, annual_budget_manager: @manager, selected_month: 11, raw_input: message, command: command).call
    assert result&.proposal, result&.response
    source = @session.chat_messages.create!(role: "user", content: message)
    assistant = @session.chat_messages.create!(role: "assistant", content: result.response)
    result.proposal.create_draft!(source_chat_message: source, assistant_chat_message: assistant)
  end

  def present(draft)
    HouseholdFinance::MiaActionDraftPresenter.new(draft).call
  end
end
