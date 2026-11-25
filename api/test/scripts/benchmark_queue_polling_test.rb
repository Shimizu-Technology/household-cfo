require "minitest/autorun"
require "open3"
require "rbconfig"

class BenchmarkQueuePollingTest < Minitest::Test
  def test_rejects_database_url_routing_overrides_before_boot
    script = File.expand_path("../../script/benchmark_queue_polling.rb", __dir__)
    %w[host=example.invalid hostaddr=192.0.2.1 port=6543 host=%2Ftmp].each do |query|
      url = "postgresql://agent@localhost:5432/vera_polling_bench_20261119?#{query}"
      stdout, stderr, status = Open3.capture3({ "RAILS_ENV" => "test", "DATABASE_URL" => url }, RbConfig.ruby, script)

      assert_equal 1, status.exitstatus, query
      assert_empty stdout
      assert_equal "Database routing overrides are forbidden\n", stderr
    end
  end
end
