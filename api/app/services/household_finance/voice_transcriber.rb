# frozen_string_literal: true

require "json"
require "net/http"
require "securerandom"
require "uri"

module HouseholdFinance
  class VoiceTranscriber
    Result = Struct.new(:transcript, :error, keyword_init: true) do
      def success?
        error.blank?
      end
    end

    OPENROUTER_TRANSCRIPTION_URL = "https://openrouter.ai/api/v1/audio/transcriptions"
    DEFAULT_MODEL = "openai/whisper-large-v3"
    DEFAULT_LANGUAGE = "en"
    LEGACY_GROQ_MODELS = %w[whisper-large-v3 whisper-large-v3-turbo].freeze
    OPEN_TIMEOUT_SECONDS = 5
    READ_TIMEOUT_SECONDS = 30

    def initialize(file:, api_key: ENV["OPENROUTER_API_KEY"], model: nil, language: nil)
      @file = file
      @api_key = api_key.to_s.strip
      @model = normalize_model(model.presence || configured_model)
      configured_language = language.nil? ? ENV.fetch("MIA_TRANSCRIPTION_LANGUAGE", DEFAULT_LANGUAGE) : language
      @language = normalize_language(configured_language)
    end

    def call
      return failure("Voice transcription is not configured.") if api_key.blank?
      return failure("Audio file is missing.") unless file&.respond_to?(:tempfile)

      response = request_transcription
      return failure("Voice transcription failed. Please try again.") unless response.is_a?(Net::HTTPSuccess)

      transcript = JSON.parse(response.body).fetch("text", "").to_s.squish
      return failure("Voice transcription was blank. Please try again.") if transcript.blank?

      Result.new(transcript: transcript)
    rescue JSON::ParserError, KeyError
      failure("Voice transcription failed. Please try again.")
    rescue Net::OpenTimeout, Net::ReadTimeout
      failure("Voice transcription timed out. Please try again.")
    rescue StandardError => e
      Rails.logger.warn("[HouseholdFinance::VoiceTranscriber] transcription failed: #{e.class}: #{e.message}")
      failure("Voice transcription failed. Please try again.")
    end

    private

    attr_reader :file, :api_key, :model, :language

    def request_transcription
      uri = URI(OPENROUTER_TRANSCRIPTION_URL)
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{api_key}"
      request["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
      request["HTTP-Referer"] = "https://github.com/Shimizu-Technology/household-cfo"
      request["X-Title"] = "Household CFO Method Mia Voice Transcription"
      request.body = multipart_body

      Net::HTTP.start(
        uri.hostname,
        uri.port,
        use_ssl: true,
        open_timeout: OPEN_TIMEOUT_SECONDS,
        read_timeout: READ_TIMEOUT_SECONDS
      ) do |http|
        http.request(request)
      end
    end

    def multipart_body
      parts = [
        field_part("model", model),
        field_part("response_format", "json"),
        field_part("temperature", "0")
      ]
      parts << field_part("language", language) if language.present?
      parts << file_part
      parts << "--#{boundary}--\r\n"

      binary_join(*parts)
    end

    def configured_model
      openrouter_model = ENV["OPENROUTER_TRANSCRIPTION_MODEL"].to_s.strip
      return openrouter_model if openrouter_model.present?

      ENV["MIA_TRANSCRIPTION_MODEL"].to_s.strip.presence || DEFAULT_MODEL
    end

    def normalize_model(value)
      model_name = value.to_s.strip
      return DEFAULT_MODEL if model_name.blank?
      return DEFAULT_MODEL if model_name.in?(LEGACY_GROQ_MODELS)

      model_name
    end

    def normalize_language(value)
      language_code = value.to_s.strip
      return nil if language_code.blank?
      return nil if language_code.casecmp("auto").zero? || language_code.casecmp("detect").zero?

      language_code
    end

    def boundary
      @boundary ||= "----HouseholdCfoMiaVoice#{SecureRandom.hex(12)}"
    end

    def field_part(name, value)
      binary_join(
        "--#{boundary}\r\n",
        "Content-Disposition: form-data; name=\"#{name}\"\r\n\r\n",
        value.to_s,
        "\r\n"
      )
    end

    def file_part
      filename = upload_filename.gsub(/["\r\n]/, "_")
      content_type = upload_content_type
      contents = File.binread(file.tempfile.path)

      binary_join(
        "--#{boundary}\r\n",
        "Content-Disposition: form-data; name=\"file\"; filename=\"#{filename}\"\r\n",
        "Content-Type: #{content_type}\r\n\r\n",
        contents,
        "\r\n"
      )
    end

    def upload_filename
      return "mia-voice.webm" unless file.respond_to?(:original_filename)

      File.basename(file.original_filename.to_s.presence || "mia-voice.webm")
    end

    def upload_content_type
      return "application/octet-stream" unless file.respond_to?(:content_type)

      file.content_type.to_s.presence || "application/octet-stream"
    end

    def binary_join(*parts)
      parts.each_with_object(String.new(encoding: Encoding::BINARY)) do |part, buffer|
        buffer << part.to_s.b
      end
    end

    def failure(error)
      Result.new(error: error)
    end
  end
end
