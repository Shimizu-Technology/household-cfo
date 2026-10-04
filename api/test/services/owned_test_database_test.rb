require "test_helper"
require_relative "../support/owned_test_database"

class OwnedTestDatabaseTest < ActiveSupport::TestCase
  test "explicit base and exact current Rails worker database are allowed" do
    assert allowed?("owned_test", worker: nil)
    assert allowed?("owned_test_0", worker: 0)
    assert allowed?("owned_test_12", worker: 12)
    assert allowed?("owned.test_0", worker: 0, base: "owned.test")
  end

  test "arbitrary or another numeric worker database cannot authorize cleanup" do
    %w[production other_test owned_test_0 owned_test_01 owned_test_1_backup owned_test_extra].each do |database|
      assert_raises(RuntimeError) { allowed?(database, worker: 1) }
    end
    assert_raises(RuntimeError) { allowed?("ownedXtest_0", worker: 0, base: "owned.test") }
    assert_raises(RuntimeError) { allowed?("owned_test_0", worker: nil) }
    assert_raises(RuntimeError) { allowed?("owned_test", worker: 0) }
  end

  test "missing explicit base malformed worker and non test environment fail closed" do
    [ nil, "", " ", " owned_test", "owned_test " ].each do |base|
      assert_raises(RuntimeError) { allowed?("owned_test", worker: nil, base: base) }
    end
    [ -1, "0", 0.5 ].each do |worker|
      assert_raises(RuntimeError) { allowed?("owned_test_0", worker: worker) }
    end
    assert_raises(RuntimeError) { allowed?("owned_test", worker: nil, test_environment: false) }
  end

  test "both connection configuration and actual PostgreSQL database must agree" do
    assert_raises(RuntimeError) { allowed?("owned_test_0", worker: 0, configured: "other_test_0") }
    assert_raises(RuntimeError) { allowed?("other_test_0", worker: 0, configured: "owned_test_0") }
  end

  test "real runner connection belongs to the configured base or its exact Rails worker" do
    assert OwnedTestDatabase.assert!(connection: ApplicationRecord.connection)
  end

  private

  def allowed?(actual, worker:, base: "owned_test", configured: actual, test_environment: true)
    connection = Object.new
    pool = Struct.new(:db_config).new(Struct.new(:database).new(configured))
    connection.define_singleton_method(:pool) { pool }
    connection.define_singleton_method(:select_value) { |_query| actual }
    OwnedTestDatabase.assert!(connection: connection, base: base, worker_id: worker, test_environment: test_environment)
  end
end
