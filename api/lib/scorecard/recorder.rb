require "tmpdir"
require "marcel"
require "active_support/testing/time_helpers"

module Scorecard
  class Recorder
    extend ActiveSupport::Testing::TimeHelpers
    def self.call(root:, api_key:, progress: $stderr, refresh: false)
      raise "Recording requires the test database" unless Rails.env.test? && ActiveRecord::Base.connection_db_config.database.match?(/(?:\A|_)test(?:_|\z)/) && !ActiveRecord::Base.connection_db_config.database.match?(/production/i)
      root = Pathname.new(root).realpath
      raise "Recording is restricted to the committed Talun fixtures" unless root == Rails.root.join("test/fixtures/files/documents/talun-year").realpath
      manifest = JSON.parse(root.join("manifest.json").read)
      Rails.application.eager_load!
      finish = Date.iso8601(manifest.fetch("period").fetch("end_on"))
      travel_to(finish.end_of_day + 1.day) do
        record_documents(root, manifest, api_key, progress, refresh)
      end
    end

    def self.record_documents(root, manifest, api_key, progress, refresh)
      Dir.mktmpdir("scorecard-record-") do |storage|
        previous = ENV.to_h.slice("STORAGE_BACKEND", "LOCAL_STORAGE_ROOT")
        ENV["STORAGE_BACKEND"], ENV["LOCAL_STORAGE_ROOT"] = "local", File.realpath(storage)
        queue = Queue.new
        manifest.fetch("documents").each_with_index { |doc, index| queue << [ doc, index ] if refresh || !root.join("recorded_responses", doc.fetch("path") + ".json").exist? }
        errors = Queue.new
        workers = Array.new(4) do
          Thread.new do
            while (pair = queue.pop(true) rescue nil)
              doc, index = pair
              begin
                ActiveRecord::Base.connection_pool.with_connection do
                  User.transaction(requires_new: true) do
                    user = User.create!(clerk_id: "record-#{SecureRandom.hex(10)}", email: "record-#{SecureRandom.hex(10)}@example.invalid", role: "participant", invitation_status: "accepted")
                    household = HouseholdFinance::WorkspaceResolver.new(user).household
                    manifest.fetch("categories").each_with_index do |name, sort_order|
                      household.budget_categories.create!(name: name, stack_key: "discretionary", sort_order: sort_order, active: true)
                    end
                    path = root.join(doc.fetch("path"))
                    document = household.financial_document_imports.create!(uploaded_by_user: user, filename: path.basename.to_s, content_type: Marcel::MimeType.for(path), byte_size: path.size, document_kind: doc["kind"] == "receipt" ? "receipt" : "statement", s3_key: "record/#{index}")
                    S3Service.upload_file!(document.s3_key, path, content_type: document.content_type, checksum_sha256: doc.fetch("sha256"))
                    extractor = RecordedExtractor.new(path: root.join("recorded_responses", doc.fetch("path") + ".json"), source: path, record: true, api_key: api_key)
                    result = extractor.call(document)
                    progress.puts "#{index + 1}/#{manifest.fetch('documents').length}: #{result.success? ? 'recorded' : 'failed'}"
                    raise "Recording extraction failed: #{result.error}; #{result.metadata[:error_detail]}" unless result.success?
                    raise ActiveRecord::Rollback
                  end
                end
              rescue StandardError => error
                errors << error
              end
            end
          end
        end
        workers.each(&:join)
        raise errors.pop unless errors.empty?
      ensure
        %w[STORAGE_BACKEND LOCAL_STORAGE_ROOT].each { |key| previous.key?(key) ? ENV[key] = previous[key] : ENV.delete(key) }
      end
    end
    private_class_method :record_documents
  end
end
