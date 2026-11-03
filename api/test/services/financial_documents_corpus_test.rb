require "test_helper"
require "digest"
require "marcel"

class FinancialDocumentsCorpusTest < ActiveSupport::TestCase
  ROOT = Rails.root.join("test/fixtures/files/documents")
  MANIFEST = JSON.parse(ROOT.join("manifest.json").read)

  test "every committed synthetic source has verified bytes and independently reconciled expected arithmetic" do
    assert_equal 25, MANIFEST.fetch("document_count")
    assert_equal 25, MANIFEST.fetch("documents").length
    assert_operator MANIFEST["documents"].sum { |d| d["size_bytes"] }, :<, 15.megabytes
    MANIFEST["documents"].each do |doc|
      path = ROOT.join(doc["filename"])
      assert doc["synthetic"], doc["filename"]
      assert_equal doc["sha256"], Digest::SHA256.file(path).hexdigest, doc["filename"]
      assert_equal doc["size_bytes"], path.size
      events = doc.fetch("expected_events")
      assert_equal doc["expected_source_event_count"], events.length
      posted = events.select { |e| e["status"] == "posted" }
      assert_equal doc["expected_posted_event_count"], posted.length
      spending = posted.select { |e| %w[purchase fee interest].include?(e["event_type"]) && e["signed_amount_cents"].negative? }
      assert_equal doc["expected_spending_draft_count"], spending.length
      totals = doc["totals_cents"]
      if totals.any?
        assert_equal posted.sum { |e| [ e["signed_amount_cents"], 0 ].max }, totals["printed_credit_cents"]
        assert_equal posted.sum { |e| [ -e["signed_amount_cents"], 0 ].max }, totals["printed_debit_cents"]
        assert_equal spending.sum { |e| -e["signed_amount_cents"] }, totals["spending_draft_total_cents"]
        if totals["opening_balance_cents"]
          net = totals["printed_credit_cents"] - totals["printed_debit_cents"]
          assert_equal totals["opening_balance_cents"] + net * (doc["account_basis"] == "liability" ? -1 : 1), totals["closing_balance_cents"]
        end
      end
      if doc["receipt_items"]
        assert_equal doc["receipt_total_cents"], doc["receipt_items"].sum { |i| i["amount_cents"] } + doc["tip_cents"] + doc["tax_cents"]
        assert_equal doc["receipt_total_cents"], totals["spending_draft_total_cents"]
      end
      if doc["paystub"]
        stub = doc["paystub"]
        assert_equal stub["gross_cents"] - stub["deductions_cents"].values.sum, stub["net_cents"]
        assert_equal stub["net_cents"] * stub["ytd_period_count"], stub["ytd_net_cents"]
      end
    end
  end

  MANIFEST["documents"].each do |doc|
    test "extract corpus #{doc['filename']} with offline recorded provider responses" do
      path = ROOT.join(doc["filename"])
      mime = Marcel::MimeType.for(path, name: doc["filename"])
      kind = { "budget" => "spreadsheet", "statement_screenshot" => "statement", "retirement_statement" => "statement" }.fetch(doc["kind"], doc["kind"])
      user = User.create!(clerk_id: "corpus-#{SecureRandom.hex(8)}", email: "corpus-#{SecureRandom.hex(8)}@example.invalid", role: "participant", invitation_status: "accepted")
      household = HouseholdFinance::WorkspaceResolver.new(user).household
      document = FinancialDocumentImport.new(household: household, uploaded_by_user: user, document_kind: kind, filename: doc["filename"], content_type: mime, s3_key: "synthetic-only/#{doc['filename']}")
      recording = ROOT.join("recorded_responses", doc["filename"] + ".json")
      responses = recording.exist? ? JSON.parse(recording.read).fetch("responses").dup : []
      extractor = FinancialDocuments::Extractor.new(api_key: "offline-fixture")
      assertions = self
      requested_label = nil
      original_extract = extractor.method(:extract_openrouter_document)
      extractor.define_singleton_method(:extract_openrouter_document) do |*args, **options|
        requested_label = options[:batch_label]
        original_extract.call(*args, **options)
      end
      extractor.define_singleton_method(:perform_openrouter_request) do |payload|
        raise "Unexpected provider call for #{doc['filename']}" if responses.empty?
        recorded = responses.shift
        if recorded.fetch("label").nil?
          assertions.assert_nil requested_label, "#{doc['filename']}: unbatched recording must not answer a source section"
        else
          assertions.assert_equal recorded.fetch("label"), requested_label, "#{doc['filename']}: recorded batch must match the requested source section"
          assertions.assert_includes payload.dig(:messages, 1, :content).first.fetch(:text), "This file is #{recorded.fetch("label")}."
        end
        raw = recorded.fetch("response").deep_symbolize_keys
        FinancialDocuments::Extractor::Result.new(**raw)
      end
      singleton = S3Service.singleton_class
      originals = %i[configured? download_to_io].to_h { |name| [ name, singleton.instance_method(name) ] }
      singleton.define_method(:configured?) { true }
      singleton.define_method(:download_to_io) { |_key, io| io.write(File.binread(path)); true }
      begin
        result = extractor.call(document)
        assert result.success?, "#{doc['filename']}: #{result.error}; #{result.metadata[:error_detail]}"
        native = result.metadata[:extraction_mode] == "native_statement"
        if native
          assert_equal 1, responses.length, "Reconciled text PDFs must not call the provider"
        else
          assert_empty responses, "Every recorded provider section must be consumed"
        end
        accounting = result.data.fetch(:source_accounting)
        events = accounting.fetch(:events)
        assert_equal doc["expected_source_event_count"], events.length
        financial_items = result.data.fetch(:items).reject { |item| item[:target_type] == "profile_note" }
        assert_equal native ? 0 : doc["expected_item_count"], financial_items.length
        result.data[:items].select { |item| item[:target_type] == "profile_note" }.each do |note|
          assert_nil note[:amount_cents]
          assert_nil note[:balance_cents]
          assert_match(/tobacco|cigarette/i, [ note[:label], note[:evidence] ].join(" "))
          assert_equal "budget-messy-600-rows-2026.xlsx", doc["filename"]
        end
        if doc["kind"] == "receipt"
          drafts = result.data.fetch(:transaction_drafts)
          assert_equal 1, drafts.length
          assert_equal doc["receipt_total_cents"], drafts.sole[:total_amount_cents]
          assert_equal doc["period_start_on"], drafts.sole[:occurred_on].to_s
          assert_equal doc["receipt_total_cents"], drafts.sole[:splits].sum { |split| split[:amount_cents] }
          if doc["filename"].include?("payless")
            assert drafts.sole[:splits].any? { |split| split[:amount_cents] == 1_800 && split[:category_name].to_s.match?(/tobacco|cigarette/i) }
          end
          next
        end
        expected = doc.fetch("expected_events").map { |e| [ e["row_kind"] == "posted" ? e["posted_on"] : nil, e["row_kind"] == "posted" ? e["signed_amount_cents"] : nil, e["row_kind"] ] }.sort_by(&:to_s)
        actual = events.map { |e| [ e[:row_kind] == "posted" ? e[:posted_on]&.to_s : nil, e[:signed_amount_cents], e[:row_kind] ] }.sort_by(&:to_s)
        assert_equal expected, actual
        if events.any?
          assert_equal 1, doc["expected_events"].pluck("account_key").uniq.length
          account = accounting[:accounts].sole
          assert_equal [ account[:source_key] ], events.pluck(:source_key).uniq
          if %w[csv xlsx].include?(doc["format"])
            assert_equal "unknown", account[:account_basis], "Exports do not print account identity or basis"
          else
            assert_equal doc["account_basis"], account[:account_basis]
            number = doc["fictional_account"] || doc["expected_events"].first["account_key"][/\d+\z/]
            assert_equal number[-4, 4], account.dig(:evidence, :masked_identifier).to_s.gsub(/\D/, "").last(4)
          end
          doc["expected_events"].select { |event| event["row_kind"] == "posted" }.each do |event|
            match = events.find { |row| row[:posted_on]&.to_s == event["posted_on"] && row[:signed_amount_cents] == event["signed_amount_cents"] }
            assert match, "Missing source row #{event['event_id']}"
            assert_includes event.fetch("allowed_event_types", [ event["event_type"] ]), match[:event_type], event["description"]
          end
        end
        eligible = events.select { |e| e[:row_kind] == "posted" && e[:expense_amount_cents].to_i.positive? }
        assert_equal doc["expected_spending_draft_count"], eligible.length
        assert_equal doc.dig("totals_cents", "spending_draft_total_cents").to_i, eligible.sum { |e| e[:expense_amount_cents] }
        assert_equal doc.fetch("expected_events").map { |e| e["posted_on"][0, 7] }.uniq.sort, events.filter_map { |e| e[:posted_on]&.strftime("%Y-%m") }.uniq.sort
        (native ? [] : doc["expected_items"]).each do |item|
          candidate = result.data[:items].find { |i| i[:target_type] == item["type"] && (i[:label] == item["label"] || doc["kind"] == "pay_stub") }
          assert candidate, "Missing #{item['label']}"
          if doc["kind"] == "pay_stub"
            multiplier = { "monthly" => 1, "semi_monthly" => 2, "biweekly" => 26.0 / 12, "weekly" => 52.0 / 12 }.fetch(candidate[:cadence])
            assert_equal item["monthly_equivalent_cents"], (candidate[:amount_cents] * multiplier).round
          else
            assert_equal item["amount_cents"], candidate[:amount_cents] || candidate[:balance_cents]
            assert_equal item["cadence"], candidate[:cadence]
          end
        end
      ensure
        originals.each { |name, method| singleton.define_method(name, method) }
      end
    end
  end
end
