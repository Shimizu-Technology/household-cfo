require "digest"

module Scorecard
  # Replays the provider boundary only. Native parsers, normalization and
  # persistence still run. Recordings are observations, never the answer key.
  class RecordedExtractor < FinancialDocuments::Extractor
    attr_reader :recording, :replay_error

    def initialize(path:, source:, record: false, api_key: nil)
      super(api_key: record ? api_key : "offline-scorecard")
      @path, @source, @record = Pathname.new(path), source, record
      @recording = if @path.exist? && !record
        JSON.parse(@path.read)
      else
        { "sha256" => Digest::SHA256.file(source).hexdigest, "model" => model,
          "prompt_version" => PROMPT_VERSION, "responses" => [] }
      end
      raise "Recording source changed; re-record the fictional source" unless @recording.fetch("sha256") == Digest::SHA256.file(source).hexdigest
      unless @record || (@recording["model"] == model && @recording["prompt_version"] == PROMPT_VERSION)
        raise "Recording model or PROMPT_VERSION changed; re-record the fictional source"
      end
      @remaining = @recording.fetch("responses").deep_dup
    end

    def call(document, &block)
      result = super
      raise @replay_error if @replay_error
      native = result.metadata[:extraction_mode] == "native_statement"
      # A newly supported native template may bypass an older recording. Like
      # the corpus tests, permit that only when no recorded section was consumed.
      consumed = @recording.fetch("responses").length - @remaining.length
      fail_replay!("Unused recorded provider sections; re-record the fictional source") unless @record || @remaining.empty? || native && consumed.zero?
      if @record && result.success?
        @path.dirname.mkpath
        @path.write(JSON.pretty_generate(recording) + "\n")
      end
      result
    end

    # Hash the complete request, including category context and source bytes.
    # Object key order is immaterial; array order and all values are preserved.
    def self.request_digest(payload)
      canonical = lambda do |value|
        case value
        when Hash then value.stringify_keys.sort.to_h.transform_values { |item| canonical.call(item) }
        when Array then value.map { |item| canonical.call(item) }
        else value
        end
      end
      Digest::SHA256.hexdigest(JSON.generate(canonical.call(payload)))
    end

    private

    def fail_replay!(message)
      raise(@replay_error = RuntimeError.new(message))
    end

    def extract_openrouter_document(*args, **options)
      @label = options[:batch_label]
      super
    end

    def perform_openrouter_request(payload)
      if @record
        result = super
        recording["responses"] << { "label" => @label, "request_sha256" => self.class.request_digest(payload), "response" => result.to_h }
        result
      else
        entry = @remaining.shift || fail_replay!("Unrecorded provider request; re-record the fictional source; network is disabled")
        fail_replay!("Recording section changed; re-record the fictional source") unless entry.fetch("label") == @label
        unless entry["request_sha256"] == self.class.request_digest(payload)
          fail_replay!("Recording request payload changed; re-record with the runner categories, prompt and model")
        end
        Result.new(**entry.fetch("response").deep_symbolize_keys)
      end
    end
  end
end
