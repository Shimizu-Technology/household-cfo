require "test_helper"
require "tmpdir"
require Rails.root.join("lib/ci_test_shards")

class CiTestShardsTest < ActiveSupport::TestCase
  test "every test file lands in exactly one shard" do
    root = Rails.root.to_s
    shards = (1..3).map { |index| CiTestShards.files(root: root, index: index, total: 3) }

    assert_equal CiTestShards.all_files(root), shards.flatten.sort
    assert_equal shards.flatten.length, shards.flatten.uniq.length
    assert shards.all?(&:any?)
  end

  test "the split is deterministic and balanced by file size" do
    Dir.mktmpdir("ci-shards-") do |root|
      FileUtils.mkdir_p(File.join(root, "test/models"))
      FileUtils.mkdir_p(File.join(root, "test/system"))
      { "a" => 1000, "b" => 900, "c" => 500, "d" => 400, "e" => 100 }.each do |name, size|
        File.write(File.join(root, "test/models/#{name}_test.rb"), "#" * size)
      end
      File.write(File.join(root, "test/system/skipped_test.rb"), "#")
      File.write(File.join(root, "test/models/helper.rb"), "#")

      first = CiTestShards.files(root: root, index: 1, total: 2)
      assert_equal first, CiTestShards.files(root: root, index: 1, total: 2)
      assert_equal %w[test/models/a_test.rb test/models/d_test.rb test/models/e_test.rb], first
      assert_equal %w[test/models/b_test.rb test/models/c_test.rb], CiTestShards.files(root: root, index: 2, total: 2)
    end
  end

  test "a measured weight beats file size, and a file without one is estimated from its size" do
    Dir.mktmpdir("ci-shards-") do |root|
      FileUtils.mkdir_p(File.join(root, "test/models"))
      FileUtils.mkdir_p(File.join(root, "lib"))
      # A tiny file that is slow, and four big files that are fast.
      File.write(File.join(root, "test/models/slow_test.rb"), "#")
      %w[a b c d].each { |name| File.write(File.join(root, "test/models/#{name}_test.rb"), "#" * 10_000) }
      File.write(File.join(root, "lib/ci_test_shard_weights.json"), JSON.generate("test/models/slow_test.rb" => 100.0))

      assert_equal %w[test/models/slow_test.rb], CiTestShards.files(root: root, index: 1, total: 2)
      assert_equal %w[test/models/a_test.rb test/models/b_test.rb test/models/c_test.rb test/models/d_test.rb], CiTestShards.files(root: root, index: 2, total: 2)
    end
  end

  test "the committed weights keep the three shards within ten percent of each other" do
    loads = CiTestShards.loads(root: Rails.root.to_s, total: 3)
    assert_operator loads.max, :<=, loads.min * 1.1, loads.inspect
  end

  # parallelize sets one executor for the whole run, so a single test class that calls it decides how every
  # test in its shard runs: parallelize(workers: 1) in one class once made a whole shard take 17 minutes.
  test "only the test helper sets the parallel workers" do
    root = Rails.root.to_s
    offenders = CiTestShards.all_files(root).select { |path| File.read(File.join(root, path)).match?(/^\s*parallelize\b/) }
    assert_empty offenders
  end

  test "an out-of-range shard is refused" do
    [ [ 0, 3 ], [ 4, 3 ], [ 1, 0 ] ].each do |index, total|
      assert_raises(ArgumentError) { CiTestShards.files(root: Rails.root.to_s, index: index, total: total) }
    end
  end
end
