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

  test "a concurrent downgrade to coach viewer wins before operation authorization" do
    membership = @household.household_memberships.find_by!(user: @user)
    downgrade_ready = Queue.new
    release_downgrade = Queue.new
    downgrader = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        HouseholdMembership.transaction do
          locked = HouseholdMembership.lock.find(membership.id)
          locked.update!(role: "coach_viewer")
          downgrade_ready << true
          release_downgrade.pop
        end
      end
    end
    downgrade_ready.pop

    runner_pid = Queue.new
    runner = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        household = Household.find(@household.id)
        user = User.find(@user.id)
        runner_pid << connection.select_value("SELECT pg_backend_pid()").to_i
        HouseholdFinance::Operations::Runner.new(household, user: user).run(
          operation_key: "budget.category.create",
          input: { name: "Blocked dining", stack_key: "discretionary", monthly_amount: 250, year: 2026 },
          idempotency_key: "downgraded-writer"
        )
      rescue => e
        e
      end
    end
    pid = runner_pid.pop
    deadline = 15.seconds.from_now
    blocked = false
    until blocked || Time.current >= deadline
      blocked = ActiveRecord::Base.connection.select_value(<<~SQL.squish) == "Lock"
        SELECT wait_event_type
        FROM pg_stat_activity
        WHERE pid = #{Integer(pid)}
      SQL
      sleep 0.01 unless blocked
    end
    assert blocked, "expected the operation to wait for the locked membership row"
    release_downgrade << true

    error = runner.value
    downgrader.value
    assert_instance_of HouseholdFinance::Operations::Runner::InvalidPreparedOperation, error
    assert_includes error.message, "no longer have permission"
    assert_equal "coach_viewer", membership.reload.role
    refute @household.budget_categories.exists?(name: "Blocked dining")
    refute @household.household_operation_executions.exists?(idempotency_key: "downgraded-writer")
  ensure
    release_downgrade << true if downgrader&.alive?
    downgrader&.join
    runner&.join
  end
end
