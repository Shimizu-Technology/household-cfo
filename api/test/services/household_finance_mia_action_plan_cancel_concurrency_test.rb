require "test_helper"

class HouseholdFinanceMiaActionPlanCancelConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
  parallelize(workers: 1)

  setup do
    @user = User.create!(
      clerk_id: "mia_cancel_race_#{SecureRandom.hex(6)}",
      email: "mia-cancel-race-#{SecureRandom.hex(6)}@example.com",
      role: "participant",
      invitation_status: "accepted"
    )
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    @manager = HouseholdFinance::AnnualBudgetManager.new(@household, year: Date.current.year)
    @account = @household.accounts.create!(label: "Checking", account_type: "checking", balance_cents: 100_00, balance_known: true)
    @goal = @household.goals.create!(label: "Car replacement", goal_type: "other", record_kind: "tracked")
    prompt = "Set Checking to $250 and set Car replacement progress to $900"
    result = HouseholdFinance::MiaActionPlanBuilder.new(
      @household, user: @user, annual_budget_manager: @manager, selected_month: Date.current.month,
      raw_input: prompt,
      actions: [
        { source_text: "Set Checking to $250", depends_on: [], action: { type: "update_account", account_id: @account.id, account_name: @account.label, amount: "250" } },
        { source_text: "set Car replacement progress to $900", depends_on: [], action: { type: "update_goal", goal_id: @goal.id, goal_name: @goal.label, current_amount: "900" } }
      ]
    ).call
    session = @household.chat_sessions.create!(user: @user, title: "Ask Mia")
    @draft = result.proposal.create_draft!(
      source_chat_message: session.chat_messages.create!(role: "user", content: prompt),
      assistant_chat_message: session.chat_messages.create!(role: "assistant", content: result.response)
    )
  end

  teardown do
    @draft&.destroy! if @draft&.persisted?
    @household&.destroy!
    @user&.destroy!
  end

  test "concurrent cancellation with one external key records one cancellation and one replay" do
    ready = Queue.new
    start = Queue.new
    results = Queue.new
    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          draft = MiaActionDraft.find(@draft.id)
          results << HouseholdFinance::MiaActionDraftCanceler.new(draft, user: User.find(@user.id)).call(idempotency_key: "same-cancel")
        end
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    threads.each(&:join)
    outcomes = 2.times.map { results.pop }

    assert outcomes.all?(&:success?), outcomes.flat_map(&:errors).to_sentence
    assert_equal [ false, true ], outcomes.map(&:replayed?).sort_by { |value| value ? 1 : 0 }
    assert_equal 1, MiaActionDraftApplication.where(household: @household, idempotency_key: "same-cancel").count
    assert_equal 2, @draft.mia_action_items.where.not(canceled_at: nil).count
    assert_equal 1, @household.household_audit_events.where(event_type: "mia_action_draft.canceled").count
  end
end
