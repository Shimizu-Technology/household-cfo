# frozen_string_literal: true

require "json"

# Splits the Rails test files into shards for CI. The split is deterministic: the same files give the
# same shards on every runner, so each file runs in exactly one shard. Files are dealt largest first
# to the shard with the least work so far.
#
# A file's weight is its measured run time in seconds from lib/ci_test_shard_weights.json (files that take
# at least a second), or an estimate from its size for any file not listed, such as a new one. Refresh the
# weights when the shards drift apart with script/ci_test_shard_weights.rb and a green run's shard logs.
module CiTestShards
  WEIGHTS_FILE = "lib/ci_test_shard_weights.json"
  # How many shards CI runs; keep it in step with the rails_test_shard matrix in .github/workflows/ci.yml.
  SHARDS = 2
  # Seconds of run time per byte of test source, for a file without a measured weight.
  SECONDS_PER_BYTE = 0.00003

  module_function

  # Test files `bin/rails test` runs by default (system tests are separate).
  def all_files(root)
    Dir.glob("test/**/*_test.rb", base: root).reject { |path| path.start_with?("test/system/") }.sort
  end

  def weights(root)
    path = File.join(root, WEIGHTS_FILE)
    File.exist?(path) ? JSON.parse(File.read(path)) : {}
  end

  def weight(root, path, measured)
    measured.fetch(path) { File.size(File.join(root, path)) * SECONDS_PER_BYTE }
  end

  # The files for shard `index` of `total` (1-based).
  def files(root:, index:, total:)
    raise ArgumentError, "shard #{index}/#{total} is out of range" unless total.positive? && index.between?(1, total)

    measured = weights(root)
    loads = Array.new(total, 0.0)
    shards = Array.new(total) { [] }
    all_files(root).sort_by { |path| [ -weight(root, path, measured), path ] }.each do |path|
      target = loads.each_with_index.min_by { |load, position| [ load, position ] }.last
      shards[target] << path
      loads[target] += weight(root, path, measured)
    end
    shards[index - 1].sort
  end

  # Seconds of work per shard, for checking the balance.
  def loads(root:, total:)
    measured = weights(root)
    (1..total).map { |index| files(root: root, index: index, total: total).sum { |path| weight(root, path, measured) }.round(1) }
  end
end
