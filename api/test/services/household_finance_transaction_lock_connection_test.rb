require "test_helper"

class HouseholdFinanceTransactionLockConnectionTest < ActiveSupport::TestCase
  test "pinned caller transactions reuse an independent lock connection without holding its slot" do
    caller = ActiveRecord::Base.connection
    assert caller.transaction_open?
    connections = []
    2.times do
      HouseholdFinance::TransactionLockConnection.with_connection do |connection|
        refute_same caller, connection
        refute connection.transaction_open?
        connections << connection
        connection.transaction do
          assert connection.select_value("SELECT pg_try_advisory_xact_lock(19601234, 77)")
        end
      end
    end
    assert_same connections.first, connections.last, "opening a fresh backend on every pinned call can exhaust the admission deadline"
    assert caller.transaction_open?
    assert_equal 0, caller.select_value("SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND classid = 19601234 AND objid = 77").to_i
  end
end
