require "net/http"

module Scorecard
  module Offline
    def self.call
      methods = [ [ Net::HTTP.singleton_class, :start ], [ Net::HTTP, :start ], [ Net::HTTP, :request ] ]
      originals = methods.map { |owner, name| [ owner, name, owner.instance_method(name) ] }
      methods.each { |owner, name| owner.define_method(name) { |*args, **options, &block| raise "Scorecard must never use the network" } }
      yield
    ensure
      originals&.each { |owner, name, original| owner.define_method(name, original) }
    end
  end
end

require "tmpdir"
require "marcel"
require "csv"
require "active_support/testing/time_helpers"

module Scorecard
  class Runner
    include ActiveSupport::Testing::TimeHelpers
    TALUN = Rails.root.join("test/fixtures/files/documents/talun-year")
    FAST_PATHS = %w[checking-2026-01.pdf checking-2026-06.pdf bog-2026-11-phone-1.png bog-2026-11-phone-2.png bog-2026-11-phone-3.png apple-2026-01.pdf card-2026-03.pdf all-accounts-2026-01-to-06.csv receipt-voucher-2026-06-23.jpg].freeze

    FAST_CSV_ROWS = 24

    def initialize(family_dir: TALUN, answer_key: Pathname.new(family_dir).join("manifest.json"), private_mode: false, document_limit: nil, document_paths: nil, progress: nil, correct_proposals: true)
      @private_mode, @limit, @paths, @progress = private_mode, document_limit, document_paths, progress
      @correct_proposals = correct_proposals
      @fast = !private_mode && document_paths == FAST_PATHS
      @answer_key_path = answer_key
      @key = AnswerKey.new(root: family_dir, path: answer_key)
      if private_mode
        repo = Rails.root.parent.realpath.to_s + "/"
        raise ArgumentError, "Private inputs must be outside the repository" if [ Pathname.new(family_dir).realpath, Pathname.new(answer_key).realpath ].any? { |path| path.to_s.start_with?(repo) }
      else
        raise ArgumentError, "CI mode accepts only the fictional Talun family" unless @key.root == TALUN.realpath && @key.data["synthetic"] == true
      end
    end

    def call
      Offline.call { run }
    end

    private

    def run
      raise "Scorecard requires the test database" unless Rails.env.test? && ActiveRecord::Base.connection_db_config.database.match?(/(?:\A|_)test(?:_|\z)/) && !ActiveRecord::Base.connection_db_config.database.match?(/production/i)
      report = nil
      previous = ENV.to_h.slice("STORAGE_BACKEND", "LOCAL_STORAGE_ROOT")
      logger = Rails.logger
      record_logger = ActiveRecord::Base.logger
      job_logger = ActiveJob::Base.logger
      silent = ActiveSupport::Logger.new(File::NULL)
      Rails.logger = ActiveRecord::Base.logger = ActiveJob::Base.logger = silent
      Dir.mktmpdir("household-scorecard-") do |storage|
        ENV["STORAGE_BACKEND"], ENV["LOCAL_STORAGE_ROOT"] = "local", File.realpath(storage)
        finish = Date.iso8601(@key.data.fetch("period").fetch("end_on"))
        travel_to(finish.end_of_day + 1.day) do
          ApplicationRecord.transaction(requires_new: true) do
            # These small, deeply scoped review queries otherwise spend most of
            # their time compiling PostgreSQL JIT plans. SQL/results are identical.
            ApplicationRecord.connection.execute("SET LOCAL jit = off")
            user = User.create!(clerk_id: "scorecard-#{SecureRandom.hex(12)}", email: "scorecard-#{SecureRandom.hex(12)}@example.invalid", role: "participant", invitation_status: "accepted")
            household = HouseholdFinance::WorkspaceResolver.new(user).household
            categories = @key.data.fetch("categories").each_with_index.to_h do |name, index|
              category = household.budget_categories.find_or_initialize_by(name: name)
              category.assign_attributes(stack_key: "discretionary", sort_order: index, active: true)
              category.save!
              [ name, category ]
            end
            simulator = ApprovalSimulator.new(household: household, user: user, answer_key: @key, categories: categories, correct_proposals: @correct_proposals)
            documents = @limit ? @key.documents.first(@limit) : @key.documents
            documents = documents.select { |doc| @paths.include?(doc.fetch("path")) } if @paths
            documents = receipts_first(documents)
            if @fast
              documents = documents.map { |doc| doc.fetch("path").end_with?(".csv") ? doc.merge("lines" => doc.fetch("lines").first(FAST_CSV_ROWS)) : doc }
            end
            @storage = storage
            documents.each_with_index do |doc, index|
              document = import(household, user, doc, index)
              # A rollback-only run is invisible to autovacuum. Refresh planner
              # statistics for the growing fixture ledger in this isolated DB.
              ApplicationRecord.connection.execute("ANALYZE financial_document_imports, financial_extraction_revisions, financial_source_events, financial_source_accounts, source_review_heads, source_review_versions, source_review_drafts, source_account_review_heads, source_account_identity_versions")
              simulator.call(document, doc)
              @progress&.call(index + 1, documents.length)
            end
            simulator.reconfirm_stale_coverage
            report = Report.new(household: household, answer_key: @key, simulator: simulator, documents: documents).call
            raise ActiveRecord::Rollback
          end
        end
      end
      if @private_mode
        report["distinct_purchase_groups"] = report.fetch("distinct_purchase_groups").values.each_with_index.to_h { |value, index| [ "group_#{index + 1}", value ] }
      end
      if @correct_proposals
        uncorrected = self.class.new(family_dir: @key.root, answer_key: @answer_key_path, private_mode: @private_mode,
          document_limit: @limit, document_paths: @paths, correct_proposals: false).call
        report["uncorrected"] = uncorrected.slice("months", "annual", "source_coverage", "distinct_purchase_groups")
      end
      report
    ensure
      if previous
        %w[STORAGE_BACKEND LOCAL_STORAGE_ROOT].each { |key| previous.key?(key) ? ENV[key] = previous[key] : ENV.delete(key) }
        Rails.logger = logger
        ActiveRecord::Base.logger = record_logger
        ActiveJob::Base.logger = job_logger
      end
    end

    private

    # A receipt is imported before the first statement that covers its day, so its purchase is confirmed before the
    # bank line for it is reviewed (the line then asks "Same purchase as your receipt …?"). Order is otherwise the manifest's.
    def receipts_first(documents)
      receipts, others = documents.partition { |doc| doc["kind"] == "receipt" }
      receipts.each do |receipt|
        day = receipt.fetch("period").fetch("start_on")
        index = others.index { |doc| doc["kind"] != "receipt" && doc.fetch("period").fetch("start_on") <= day && day <= doc.fetch("period").fetch("end_on") }
        others.insert(index || others.length, receipt)
      end
      others
    end

    def import(household, user, doc, index)
      path = @key.source(doc)
      recording_path = @key.root.join("recorded_responses", doc.fetch("path") + ".json")
      checksum = doc.fetch("sha256")
      if @fast && path.extname == ".csv"
        # Native extraction still reads actual CSV bytes. Only CI approval scope
        # is shortened; the full-year run always uses the original 298 rows.
        slice = Pathname.new(@storage).join(path.basename)
        CSV.open(slice, "wb") { |output| CSV.foreach(path).take(FAST_CSV_ROWS + 1).each { |row| output << row } }
        path = slice
        checksum = Digest::SHA256.file(path).hexdigest
        # A native-only slice has no provider observations. Any future model
        # dependency must fail closed, rather than replay the full-file response.
        recording_path = Pathname.new(@storage).join("native-csv-recording.json")
      end
      document = household.financial_document_imports.create!(uploaded_by_user: user, filename: path.basename.to_s,
        content_type: Marcel::MimeType.for(path), byte_size: path.size, checksum_sha256: checksum,
        document_kind: doc["kind"] == "receipt" ? "receipt" : "statement", s3_key: "scorecard/#{user.clerk_id}/#{index}")
      S3Service.upload_file!(document.s3_key, path, content_type: document.content_type, checksum_sha256: checksum)
      # Same durable dispatch, extraction job, routing, source ledger and draft
      # persistence as an upload. HTTP authentication/rate limits are out of scope.
      dispatch = FinancialDocumentExtractionDispatch.request!(document)
      extractor = RecordedExtractor.new(path: recording_path, source: path)
      job = ExtractionJob.new
      job.scorecard_extractor = extractor
      job.perform(document.id, dispatch.id, dispatch.generation)
      raise extractor.replay_error if extractor.replay_error
      raise "Scorecard extraction failed at document #{index + 1}: #{document.attempts.order(:id).last&.error}" if document.reload.status == "failed"
      document
    end
  end
end

Dir[File.join(__dir__, "*.rb")].sort.each { |path| require path unless path == __FILE__ }
