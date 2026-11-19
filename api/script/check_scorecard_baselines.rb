# This check needs Ruby and git, not Rails, PostgreSQL or provider access.
require "json"
require "open3"
require_relative "../lib/scorecard/ratchet"

base = ARGV.fetch(0)
root = File.expand_path("../..", __dir__)
failures = %w[baseline.json baseline-fast.json].flat_map do |name|
  path = "api/test/fixtures/files/documents/talun-year/#{name}"
  listing, error, status = Open3.capture3("git", "ls-tree", "--name-only", base, "--", path, chdir: root)
  abort error unless status.success?
  if listing.empty?
    puts "#{name}: new baseline (no baseline at merge base)"
    next []
  end
  original, error, status = Open3.capture3("git", "show", "#{base}:#{path}", chdir: root)
  abort error unless status.success?
  begin
    current = JSON.parse(File.read(File.join(root, path)))
    Scorecard::Ratchet.regressions(current, JSON.parse(original)).map { |metric| "#{name}: #{metric}" }
  rescue ArgumentError, KeyError, Errno::ENOENT => error
    [ "#{name}: #{error.message}" ]
  end
end
if failures.any?
  reason = ENV.fetch("PR_BODY", "")[/^Scorecard baseline override: (.+)$/, 1].to_s.strip
  abort "Baseline regressions require an explicit PR explanation (Scorecard baseline override: reason):\n#{failures.join("\n")}" if reason.length < 20
  puts "Explicit baseline migration override: #{reason}"
  puts failures
else
  puts "Committed scorecard baselines do not regress the merge base."
end
