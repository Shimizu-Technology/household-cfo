require "test_helper"

class HouseholdFinanceOperationsConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @user = User.create!(
      clerk_id: "clerk_concurrency_#{SecureRandom.hex(8)}",
      email: "operation-concurrency-#{SecureRandom.hex(8)}@example.com",
      role: "participant",
      invitation_status: "accepted"
    )
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
  end

  teardown do
    @household&.destroy! if @household&.persisted?
    @user&.destroy! if @user&.persisted?
  end

  test "concurrent retries with one key create one effect audit and ledger row" do
    ready = Queue.new
    release = Queue.new
    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          release.pop
          household = Household.find(@household.id)
          user = User.find(@user.id)
          HouseholdFinance::Operations::Runner.new(household, user: user).run(
            operation_key: "budget.category.create",
            input: { name: "Dining", stack_key: "discretionary", monthly_amount: 250, year: 2026 },
            idempotency_key: "concurrent-create"
          )
        end
      end
    end
    2.times { ready.pop }
    2.times { release << true }
    results = threads.map(&:value)

    assert_equal 1, results.count(&:replayed?)
    assert_equal 1, results.count { |result| !result.replayed? }
    assert_equal 1, @household.budget_categories.where(name: "Dining").count
    assert_equal 1, @household.household_operation_executions.where(idempotency_key: "concurrent-create").count
    assert_equal 1, @household.household_audit_events.where(event_type: "household_operation.executed").count
  end

  test "concurrent income source retries create one source and replay the second request" do
    ready = Queue.new
    release = Queue.new
    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          release.pop
          household = Household.find(@household.id)
          user = User.find(@user.id)
          HouseholdFinance::Operations::Runner.new(household, user: user).run(
            operation_key: "income.source.create",
            input: { label: "Consulting", source_type: "business", amount: 1_200, cadence: "monthly", starts_on: "2026-10-01", year: 2026 },
            idempotency_key: "concurrent-income-create"
          )
        end
      end
    end
    2.times { ready.pop }
    2.times { release << true }
    results = threads.map(&:value)

    assert_equal 1, results.count(&:replayed?)
    assert_equal 1, results.count { |result| !result.replayed? }
    assert_equal 1, @household.income_sources.where(label: "Consulting").count
    assert_equal 1, @household.household_operation_executions.where(idempotency_key: "concurrent-income-create").count
    assert_equal 1, @household.household_audit_events.where(event_type: "household_operation.executed").count
  end
end
