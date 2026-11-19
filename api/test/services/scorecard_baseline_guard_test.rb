require "test_helper"
require "open3"
require "tmpdir"

class ScorecardBaselineGuardTest < ActiveSupport::TestCase
  test "CI rejects regenerated worse baselines unless the PR explains an override" do
    Dir.mktmpdir("scorecard-baseline-guard-") do |directory|
      root = Pathname.new(directory)
      %w[api/script api/lib/scorecard api/test/fixtures/files/documents/talun-year].each { |path| root.join(path).mkpath }
      %w[script/check_scorecard_baselines.rb lib/scorecard/ratchet.rb].each { |path| FileUtils.cp(Rails.root.join(path), root.join("api", path)) }
      file = root.join("api/test/fixtures/files/documents/talun-year/baseline.json")
      file.write(JSON.generate({ "decisions" => 5 }))
      git(root, "init", "--quiet")
      git(root, "add", ".")
      git(root, "-c", "user.name=Fictional Scorecard", "-c", "user.email=scorecard@example.invalid", "commit", "--quiet", "-m", "Baseline")
      command = [ RbConfig.ruby, root.join("api/script/check_scorecard_baselines.rb").to_s, "HEAD" ]
      file.write(JSON.generate({ "decisions" => 6 }))
      output, error, status = Open3.capture3({ "PR_BODY" => "" }, *command)
      refute status.success?, output
      assert_match(/baseline.json: decisions/, error)
      output, error, status = Open3.capture3({ "PR_BODY" => "Scorecard baseline override: Reviewed metric migration with explicit justification." }, *command)
      assert status.success?, error
      assert_match(/Explicit baseline migration override/, output)
      file.write(JSON.generate({ "decisions" => 4 }))
      _output, error, status = Open3.capture3({ "PR_BODY" => "" }, *command)
      assert status.success?, error
      file.delete
      _output, _error, status = Open3.capture3({ "PR_BODY" => "" }, *command)
      refute status.success?, "Deleting an existing baseline must not bypass the guard"
    end
  end

  private

  def git(root, *args)
    output, error, status = Open3.capture3("git", *args, chdir: root.to_s)
    assert status.success?, "#{output} #{error}"
  end
end
