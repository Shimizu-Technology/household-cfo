require "digest"

module Scorecard
  # Replays the provider boundary only. Native parsers, normalization and
  # persistence still run. Recordings are observations, never the answer key.
  class RecordedExtractor < FinancialDocuments::Extractor
    attr_reader :recording

    def initialize(path:, source:, record: false, api_key: nil)
      super(api_key: record ? api_key : "offline-scorecard")
      @path, @source, @record = Pathname.new(path), source, record
      @recording = if @path.exist? && !record
        JSON.parse(@path.read)
      else
        { "sha256" => Digest::SHA256.file(source).hexdigest, "model" => model,
          "prompt_version" => PROMPT_VERSION, "responses" => [] }
      end
      raise "Recording source changed" unless @recording.fetch("sha256") == Digest::SHA256.file(source).hexdigest
      @remaining = @recording.fetch("responses").deep_dup
    end

    def call(document, &block)
      result = super
      raise "Unused recorded provider sections" unless @record || @remaining.empty?
      if @record && result.success?
        @path.dirname.mkpath
        @path.write(JSON.pretty_generate(recording) + "\n")
      end
      result
    end

    private

    def extract_openrouter_document(*args, **options)
      @label = options[:batch_label]
      super
    end

    def perform_openrouter_request(payload)
      if @record
        result = super
        recording["responses"] << { "label" => @label, "response" => result.to_h }
        result
      else
        entry = @remaining.shift || raise("Unrecorded provider request; network is disabled")
        raise "Recording section changed" unless entry.fetch("label") == @label
        Result.new(**entry.fetch("response").deep_symbolize_keys)
      end
    end
  end
end
