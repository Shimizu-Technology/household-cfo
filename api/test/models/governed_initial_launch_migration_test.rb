require "test_helper"
require_relative "../../db/migrate/20261004190000_enable_governed_initial_cohort_launch"

class GovernedInitialLaunchMigrationTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "upgrading existing activation history commits replacement guards before validating" do
    migration = EnableGovernedInitialCohortLaunch.new
    validations = []
    original = migration.method(:validate_check_constraint)
    migration.define_singleton_method(:validate_check_constraint) do |table, **options|
      connection = ActiveRecord::Base.connection
      validated = connection.select_value("SELECT convalidated FROM pg_constraint WHERE conname = #{connection.quote(options.fetch(:name))}")
      lock_errors = Queue.new
      thread = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |other|
          other.transaction do
            other.execute("LOCK TABLE cohort_release_activation_events IN ACCESS SHARE MODE NOWAIT")
          end
        end
      rescue StandardError => error
        lock_errors << error
      end
      thread.join(3)
      validations << { open_transactions: connection.open_transactions, validated: validated,
        reader_finished: !thread.alive?, lock_errors: lock_errors.size.times.map { lock_errors.pop.full_message } }
      original.call(table, **options)
    end
    ActiveRecord::Migration.suppress_messages { migration.up }
    assert EnableGovernedInitialCohortLaunch.disable_ddl_transaction
    assert_equal 2, validations.length
    validations.each do |validation|
      assert_equal 0, validation[:open_transactions], "Validation retained the replacement transaction's broad lock"
      assert_equal false, validation[:validated], "Replacement checks must be NOT VALID until the scan"
      assert validation[:reader_finished]
      assert_empty validation[:lock_errors]
    end
    names = %w[release_activation_events_type_valid release_activation_events_shape]
    assert_equal 2, ActiveRecord::Base.connection.select_value("SELECT count(*) FROM pg_constraint WHERE convalidated AND conname IN (#{names.map { |name| ActiveRecord::Base.connection.quote(name) }.join(', ')})")
  end
end
