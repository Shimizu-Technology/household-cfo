# frozen_string_literal: true

# Nontransactional fixture cleanup may disable immutable-record triggers. Never
# permit it outside the explicitly named test database or Rails' current worker.
module OwnedTestDatabase
  module_function

  def assert!(connection:, base: ENV["DATABASE_TEST_NAME"], worker_id: ActiveSupport::TestCase.parallel_worker_id,
    test_environment: Rails.env.test?)
    valid_base = base.is_a?(String) && !base.strip.empty? && base == base.strip
    valid_worker = worker_id.nil? || (worker_id.is_a?(Integer) && worker_id >= 0)
    raise "Cleanup requires the configured owned test DB" unless test_environment && valid_base && valid_worker

    # Rails 8.1 ActiveRecord::TestDatabases uses exactly "#{base}_#{worker_id}".
    # A different numeric suffix is not sufficient: it must be this worker.
    expected = worker_id.nil? ? base : "#{base}_#{worker_id}"
    configured = connection.pool.db_config.database
    actual = connection.select_value("SELECT current_database()")
    raise "Cleanup requires the configured owned test DB" unless configured == expected && actual == expected

    true
  end
end
