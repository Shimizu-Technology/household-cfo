# Rewrites lib/ci_test_shard_weights.json from the logs of a CI run's Rails test shards:
#   ruby script/ci_test_shard_weights.rb shard-1.log shard-2.log
# The shards run `bin/rails test -v`, which prints each test as "Class#test_name = 1.23 s = .". The script
# adds up the seconds per test file and keeps the files that take a second or more.
require "json"

root = File.expand_path("..", __dir__)
require_relative "../lib/ci_test_shards"

abort "usage: ruby script/ci_test_shard_weights.rb LOG..." if ARGV.empty?

# Test class name => test file, from the class declarations (a class inside a top-level module gets its prefix).
files_by_class = {}
CiTestShards.all_files(root).each do |path|
  namespace = nil
  File.foreach(File.join(root, path), encoding: "UTF-8") do |line|
    if (match = line.match(/\Amodule ([A-Z][\w:]*)/))
      namespace = match[1]
    elsif (match = line.match(/\A(\s*)class ([A-Z][\w:]*)\s*</))
      name = match[1].empty? || namespace.nil? ? match[2] : "#{namespace}::#{match[2]}"
      files_by_class[name] ||= path
    end
  end
end

seconds = Hash.new(0.0)
unknown = Hash.new(0.0)
ARGV.each do |log|
  File.foreach(log, encoding: "UTF-8") do |line|
    next unless (match = line.match(/(?:\A|\s)([A-Z][\w:]*)#\S.* = (\d+\.\d+) s = /))

    if (path = files_by_class[match[1]])
      seconds[path] += match[2].to_f
    else
      unknown[match[1]] += match[2].to_f
    end
  end
end
abort "no verbose test lines found in #{ARGV.join(', ')}" if seconds.empty?

unknown.each { |name, total| warn format("No test file declares %s (%.1f s); it keeps its size estimate.", name, total) }
weights = seconds.select { |_, total| total >= 1 }.sort.to_h { |path, total| [ path, total.round(1) ] }
File.write(File.join(root, CiTestShards::WEIGHTS_FILE), JSON.pretty_generate(weights) + "\n")
puts "Wrote #{weights.size} weights (#{seconds.values.sum.round} s of tests). Shard loads: #{CiTestShards.loads(root: root, total: CiTestShards::SHARDS).inspect}"
