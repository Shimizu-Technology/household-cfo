require "test_helper"
require Rails.root.join("lib/scorecard/runner")

class ScorecardTest < ActiveSupport::TestCase
  test "Talun scorecard replays offline and never worsens the committed baseline" do
    # Fail at the network boundary, including calls introduced outside extraction.
    without_network do
      users = User.count
      households = Household.count
      full = ENV["SCORECARD_FULL"] == "1"
      report = Scorecard::Runner.new(document_paths: full ? nil : Scorecard::Runner::FAST_PATHS).call
      baseline = JSON.parse(Scorecard::Runner::TALUN.join(full ? "baseline.json" : "baseline-fast.json").read)
      assert_empty baseline_ratchet.regressions(report, baseline)
      assert_equal full ? 79 : Scorecard::Runner::FAST_PATHS.length, report.fetch("document_count")
      assert_equal report.dig("annual", "decisions_by_kind").values.sum, report.dig("annual", "decisions")
      assert_equal full ? 298 : Scorecard::Runner::FAST_CSV_ROWS, report.dig("annual", "questions_by_kind", "direction")
      assert_equal full ? 298 : Scorecard::Runner::FAST_CSV_ROWS, report.dig("annual", "decisions_by_kind", "direction")
      assert_equal users, User.count
      assert_equal households, Household.count
    end
  end

  test "ratchet allows improvements and rejects a worse monthly error" do
    baseline = { "months" => { "2026-01" => { "total_spending" => { "error_cents" => -100 }, "decisions" => 5, "matched_to_bank" => false } } }
    improved = Marshal.load(Marshal.dump(baseline))
    improved["months"]["2026-01"]["total_spending"]["error_cents"] = 0
    improved["months"]["2026-01"]["matched_to_bank"] = true
    assert_empty Scorecard::Ratchet.regressions(improved, baseline)
    improved["months"]["2026-01"]["total_spending"]["error_cents"] = 101
    assert_includes Scorecard::Ratchet.regressions(improved, baseline), "months.2026-01.total_spending.error_cents"
  end

  test "private mode rejects repository inputs" do
    assert_raises(ArgumentError) { Scorecard::Runner.new(private_mode: true) }
  end

  test "private interface replays external fictional inputs without retaining records or storage" do
    require "tmpdir"
    Dir.mktmpdir("scorecard-private-test-") do |directory|
      root = Pathname.new(directory)
      source = Scorecard::Runner::TALUN
      root.join("recorded_responses").mkpath
      %w[manifest.json checking-2026-01.pdf recorded_responses/checking-2026-01.pdf.json].each do |name|
        FileUtils.cp(source.join(name), root.join(name))
      end
      before = Dir.glob(Rails.root.join("storage/**/*").to_s).sort
      users = User.count
      result = without_network do
        Scorecard::Runner.new(family_dir: root, answer_key: root.join("manifest.json"), private_mode: true, document_limit: 1).call
      end
      assert_equal 1, result.fetch("document_count")
      assert_equal users, User.count
      assert_equal before, Dir.glob(Rails.root.join("storage/**/*").to_s).sort
      refute_includes JSON.generate(result), directory
    end
  end

  test "recordings fail closed if provider sections change" do
    root = Scorecard::Runner::TALUN
    source = root.join("checking-2026-01.pdf")
    extractor = Scorecard::RecordedExtractor.new(path: root.join("recorded_responses/checking-2026-01.pdf.json"), source: source)
    assert_raises(RuntimeError) { extractor.send(:perform_openrouter_request, {}) }
  end

  test "native extraction can bypass an older model recording without consuming it" do
    require "tmpdir"
    root = Rails.root.join("test/fixtures/files/documents")
    source = root.join("bank-of-guam-2026-09.pdf")
    Dir.mktmpdir("scorecard-native-") do |directory|
      previous = ENV.to_h.slice("STORAGE_BACKEND", "LOCAL_STORAGE_ROOT")
      ENV["STORAGE_BACKEND"], ENV["LOCAL_STORAGE_ROOT"] = "local", File.realpath(directory)
      recording = Pathname.new(directory).join("recording.json")
      observed = JSON.parse(Scorecard::Runner::TALUN.join("recorded_responses/checking-2026-01.pdf.json").read)
      observed["sha256"] = Digest::SHA256.file(source).hexdigest
      recording.write(JSON.generate(observed))
      S3Service.upload_file!("native/source", source, content_type: "application/pdf", checksum_sha256: observed.fetch("sha256"))
      document = FinancialDocumentImport.new(filename: source.basename.to_s, document_kind: "statement", content_type: "application/pdf", s3_key: "native/source")
      result = without_network { Scorecard::RecordedExtractor.new(path: recording, source: source).call(document) }
      assert result.success?, result.error
      assert_equal "native_statement", result.metadata[:extraction_mode]
    ensure
      %w[STORAGE_BACKEND LOCAL_STORAGE_ROOT].each { |key| previous.key?(key) ? ENV[key] = previous[key] : ENV.delete(key) }
    end
  end

  test "baseline_ratchet reads the base commit's ratchet when CI provides it, in its own namespace" do
    Dir.mktmpdir("scorecard-base-ratchet-") do |directory|
      path = Pathname.new(directory).join("ratchet.rb")
      path.write("module Scorecard\n  class Ratchet\n    def self.regressions(*) = [ \"base rules\" ]\n  end\nend\n")
      with_env("SCORECARD_BASE_RATCHET" => path.to_s) do
        assert_equal [ "base rules" ], baseline_ratchet.regressions({}, {})
      end
      assert_equal Scorecard::Ratchet, baseline_ratchet
      assert_empty Scorecard::Ratchet.regressions({ "decisions" => 1 }, { "decisions" => 1 })
    end
  end

  private

  def without_network
    Scorecard::Offline.call { yield }
  end

  # The ratchet that judges the committed baseline. On a pull request CI sets SCORECARD_BASE_RATCHET to the
  # base commit's lib/scorecard/ratchet.rb, so a PR can't loosen the rules and worsen the baseline together.
  # It loads into an anonymous module and leaves the PR's Scorecard::Ratchet (and its own tests) alone.
  def baseline_ratchet
    path = ENV["SCORECARD_BASE_RATCHET"].to_s
    return Scorecard::Ratchet if path.empty?

    namespace = Module.new
    namespace.module_eval(File.read(path), path)
    namespace::Scorecard::Ratchet
  end

  def with_env(values)
    saved = values.keys.index_with { |key| ENV[key] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| ENV[key] = value }
  end
end


class ScorecardQualityTest < ActiveSupport::TestCase
  test "every changed field is counted even when another question is already shown" do
    simulator, line, answer = proposal
    line.kind = :transfer
    line.event.event_type = "transfer"
    line.event.posted_on -= 1.day
    line.event.signed_amount_cents = 200
    line.category_id = nil
    entry = simulator.send(:answer_for, line, answer, "2026-01")
    assert_equal "edited", entry[:decision]
    quality = simulator.quality.fetch("2026-01")
    assert_equal 1, quality.fetch("manual_correction")
    assert_equal %w[amount category date direction type], quality.fetch("corrections_by_field").select { |_field, count| count == 1 }.keys.sort
    assert_equal 0, quality.fetch("accepted_as_proposed")
  end

  test "manual exclusions count even when the CSV asks direction" do
    simulator, line, answer = proposal
    line.kind = :direction
    simulator.instance_variable_get(:@included_legs) << answer.fetch("leg_id")
    assert_equal "leave_out", simulator.send(:answer_for, line, answer, "2026-01")[:decision]
    assert_equal 1, simulator.quality.fetch("2026-01").fetch("manual_exclusion")
    line.kind = :duplicate
    simulator.send(:answer_for, line, answer, "2026-01")
    assert_equal 1, simulator.quality.fetch("2026-01").fetch("manual_exclusion")
  end

  test "question-only approval never repairs an unasked date or amount" do
    simulator, line, answer = proposal(correct: false)
    line.event.posted_on -= 1.day
    line.event.signed_amount_cents = -200
    line.kind = :suggested_category
    line.category_id = nil
    entry = simulator.send(:answer_for, line, answer, "2026-01")
    assert_equal "edited", entry[:decision]
    assert_equal 200, entry.dig(:edit, :amount_cents)
    assert_equal "2026-01-01", entry.dig(:edit, :posted_on)
    assert_equal 7, entry.dig(:edit, :category_id)
  end

  test "accepted as proposed requires every field to match" do
    simulator, line, answer = proposal
    assert_equal "as_read", simulator.send(:answer_for, line, answer, "2026-01")[:decision]
    assert_equal 1, simulator.quality.fetch("2026-01").fetch("accepted_as_proposed")
    assert_equal 0, simulator.quality.fetch("2026-01").fetch("manual_correction")
  end

  test "ratchet rejects field corrections exclusions and question type tradeoffs" do
    baseline = { "manual_correction" => 2, "manual_exclusion" => 3, "accepted_as_proposed" => 8,
      "corrections_by_field" => { "date" => 0 }, "decisions_by_kind" => { "direction" => 4, "transfer" => 2 } }
    changed = baseline.deep_dup
    changed["manual_correction"] += 1
    changed["manual_exclusion"] += 1
    changed["accepted_as_proposed"] -= 1
    changed["corrections_by_field"]["date"] += 1
    changed["decisions_by_kind"].merge!("direction" => 3, "transfer" => 3, "new_question" => 1)
    assert_equal %w[accepted_as_proposed corrections_by_field.date decisions_by_kind.new_question decisions_by_kind.transfer manual_correction manual_exclusion], Scorecard::Ratchet.regressions(changed, baseline).sort
  end

  test "network guard blocks class and instance APIs and restores them on failure" do
    original = Net::HTTP.instance_method(:request)
    assert_raises(ArgumentError) do
      Scorecard::Offline.call do
        assert_raises(RuntimeError) { Net::HTTP.start("example.invalid") }
        assert_raises(RuntimeError) { Net::HTTP.new("example.invalid").start }
        assert_raises(RuntimeError) { Net::HTTP.new("example.invalid").request(Net::HTTP::Get.new("/")) }
        raise ArgumentError
      end
    end
    assert_equal original, Net::HTTP.instance_method(:request)
  end

  test "recording model prompt and request digest must match" do
    root = Scorecard::Runner::TALUN
    source = root.join("checking-2026-01.pdf")
    original = JSON.parse(root.join("recorded_responses/checking-2026-01.pdf.json").read)
    Dir.mktmpdir do |directory|
      path = Pathname.new(directory).join("recording.json")
      %w[model prompt_version].each do |field|
        changed = original.merge(field => "changed")
        path.write(JSON.generate(changed))
        error = assert_raises(RuntimeError) { Scorecard::RecordedExtractor.new(path: path, source: source) }
        assert_match(/re-record/, error.message)
      end
      path.write(JSON.generate(original))
      extractor = Scorecard::RecordedExtractor.new(path: path, source: source)
      extractor.instance_variable_set(:@label, original.fetch("responses").first.fetch("label"))
      error = assert_raises(RuntimeError) { extractor.send(:perform_openrouter_request, { messages: [ "different categories" ] }) }
      assert_match(/request payload changed.*re-record/, error.message)
    end
  end

  test "unmapped spending remains explicit and is ratcheted" do
    simulator = Struct.new(:row_answers, :transaction_answers).new({ 1 => { "event_id" => "fictional" } }, {})
    report = Scorecard::Report.new(household: nil, answer_key: nil, simulator: simulator, documents: [])
    transaction = Struct.new(:id, :financial_source_event_id, :total_amount_cents)
    metric = report.send(:unmapped_spending, [ transaction.new(1, 1, 100), transaction.new(2, nil, 250) ])
    assert_equal({ "unmapped_spending_cents" => 250, "unmapped_spending_count" => 1 }, metric)
    assert_equal %w[unmapped_spending_cents unmapped_spending_count], Scorecard::Ratchet.regressions(metric, { "unmapped_spending_cents" => 0, "unmapped_spending_count" => 0 }).sort
  end

  test "CSV sample expectations use only represented slice events" do
    key = Scorecard::AnswerKey.new(root: Scorecard::Runner::TALUN, path: Scorecard::Runner::TALUN.join("manifest.json"))
    csv = key.documents.find { |doc| doc.fetch("path").end_with?(".csv") }
    sliced = csv.merge("lines" => csv.fetch("lines").first(Scorecard::Runner::FAST_CSV_ROWS))
    assert_equal 2, sliced.fetch("lines").pluck("account_key").uniq.length
    assert_operator key.expected_months([ csv ]).dig("2026-02", "total_spending_cents"), :>, 0
    assert_equal 0, key.expected_months([ sliced ]).dig("2026-02", "total_spending_cents")
    assert_operator key.expected_months([ sliced ]).dig("2026-01", "total_spending_cents"), :>, 0
  end

  private

  def proposal(correct: true)
    event = { "event_kind" => "purchase", "category" => "Groceries", "date" => "2026-01-02" }
    key = Object.new
    key.define_singleton_method(:event) { |_answer| event }
    categories = { "Groceries" => Struct.new(:id).new(7) }
    simulator = Scorecard::ApprovalSimulator.new(household: nil, user: nil, answer_key: key, categories: categories, correct_proposals: correct)
    row = Struct.new(:id, :row_kind, :event_type, :signed_amount_cents, :posted_on).new(1, "posted", "purchase", -100, Date.new(2026, 1, 2))
    line = FinancialDocuments::SourceReview::ParticipantPlan::Line.new(event: row, category_id: 7)
    [ simulator, line, { "leg_id" => "fictional-leg", "signed_amount_cents" => -100, "date" => "2026-01-02" } ]
  end
end

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
