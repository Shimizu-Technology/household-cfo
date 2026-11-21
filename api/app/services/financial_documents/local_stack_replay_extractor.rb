require Rails.root.join("lib/local_stack")
require Rails.root.join("lib/scorecard/recorded_extractor")

module FinancialDocuments
  # Replays only the provider boundary for exact, committed fictional bytes.
  # Upload storage, native parsing, normalization and persistence remain real.
  class LocalStackReplayExtractor < Extractor
    ROOT = Rails.root.join("test/fixtures/files/documents/talun-year")
    NO_RECORDING = "This file has no recording. Nothing changed.".freeze

    def call(document, &progress)
      LocalStack.check_replay!
      with_source_tempfile(document) do |file|
        sha = Digest::SHA256.file(file.path).hexdigest
        manifest = JSON.parse(ROOT.join("manifest.json").read)
        fixture = manifest.fetch("documents").find do |entry|
          entry["sha256"] == sha && (entry["kind"] == "receipt" ? "receipt" : "statement") == document.document_kind
        end
        recording = fixture && ROOT.join("recorded_responses", "#{fixture.fetch('path')}.json")
        return failure(NO_RECORDING) unless recording&.file?

        result = ProviderReplay.new(path: recording, source: file.path).call(document, &progress)
        Result.new(success: result.success?, data: result.data, error: result.error,
          metadata: result.metadata.merge(local_stack_replay: true, recorded_fixture: fixture.fetch("path")))
      end
    rescue LocalStack::Refused
      raise
    rescue StandardError => error
      Rails.logger.warn("[local-stack-replay] failed_class=#{error.class}")
      failure("This file’s recording could not be read. Nothing changed.")
    end

    class ProviderReplay < Scorecard::RecordedExtractor
      private

      # A participant's categories, upload context and today's date differ from
      # the scorecard's pinned prompt. Exact source bytes, model/prompt versions
      # and section order are still checked. The scorecard keeps its stricter
      # full-request digest check; this adapter never records or calls super.
      def perform_openrouter_request(_payload)
        LocalStack.check_replay!
        entry = @remaining.shift || fail_replay!("No recorded provider section")
        fail_replay!("Recorded provider section changed") unless entry.fetch("label") == @label
        Result.new(**entry.fetch("response").deep_symbolize_keys)
      end
    end
  end
end
