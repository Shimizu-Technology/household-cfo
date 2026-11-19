# Prints the test files for one CI shard, one per line: ruby script/ci_test_shard.rb INDEX TOTAL
# It needs Ruby only, not Rails, so a shard can list its files before the database is ready.
require_relative "../lib/ci_test_shards"

index, total = ARGV.first(2).map { |value| Integer(value) }
files = CiTestShards.files(root: File.expand_path("..", __dir__), index: index, total: total)
abort "shard #{index}/#{total} has no test files" if files.empty?
puts files
