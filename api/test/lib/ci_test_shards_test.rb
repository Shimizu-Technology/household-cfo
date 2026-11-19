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

  test "an out-of-range shard is refused" do
    [ [ 0, 3 ], [ 4, 3 ], [ 1, 0 ] ].each do |index, total|
      assert_raises(ArgumentError) { CiTestShards.files(root: Rails.root.to_s, index: index, total: total) }
    end
  end
end
