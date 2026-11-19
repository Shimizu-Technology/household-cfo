require "test_helper"
require Rails.root.join("lib/scorecard")

class ScorecardTest < ActiveSupport::TestCase
  test "Talun scorecard replays offline and never worsens the committed baseline" do
    # Fail at the network boundary, including calls introduced outside extraction.
    without_network do
      users = User.count
      households = Household.count
      full = ENV["SCORECARD_FULL"] == "1"
      report = Scorecard::Runner.new(document_paths: full ? nil : Scorecard::Runner::FAST_PATHS).call
      baseline = JSON.parse(Scorecard::Runner::TALUN.join(full ? "baseline.json" : "baseline-fast.json").read)
      assert_empty Scorecard::Ratchet.regressions(report, baseline)
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

  private

  def without_network
    Scorecard::Offline.call { yield }
  end
end
