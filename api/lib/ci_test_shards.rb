# frozen_string_literal: true

# Splits the Rails test files into shards for CI. The split is deterministic: the same files give the
# same shards on every runner, so each file runs in exactly one shard. Files are dealt largest first
# to the shard with the least work so far, using file size as a stand-in for run time.
module CiTestShards
  module_function

  # Test files `bin/rails test` runs by default (system tests are separate).
  def all_files(root)
    Dir.glob("test/**/*_test.rb", base: root).reject { |path| path.start_with?("test/system/") }.sort
  end

  # The files for shard `index` of `total` (1-based).
  def files(root:, index:, total:)
    raise ArgumentError, "shard #{index}/#{total} is out of range" unless total.positive? && index.between?(1, total)

    loads = Array.new(total, 0)
    shards = Array.new(total) { [] }
    all_files(root).sort_by { |path| [ -File.size(File.join(root, path)), path ] }.each do |path|
      target = loads.each_with_index.min_by { |load, position| [ load, position ] }.last
      shards[target] << path
      loads[target] += File.size(File.join(root, path))
    end
    shards[index - 1].sort
  end
end
