require "test_helper"
require Rails.root.join("lib/scorecard")

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
