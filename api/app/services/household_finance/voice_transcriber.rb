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

    GROQ_TRANSCRIPTION_URL = "https://api.groq.com/openai/v1/audio/transcriptions"
    DEFAULT_MODEL = "whisper-large-v3-turbo"
    OPEN_TIMEOUT_SECONDS = 5
    READ_TIMEOUT_SECONDS = 30

    def initialize(file:, api_key: ENV["GROQ_API_KEY"], model: ENV.fetch("MIA_TRANSCRIPTION_MODEL", DEFAULT_MODEL))
      @file = file
      @api_key = api_key.to_s.strip
      @model = model.to_s.strip.presence || DEFAULT_MODEL
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

    attr_reader :file, :api_key, :model

    def request_transcription
      uri = URI(GROQ_TRANSCRIPTION_URL)
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{api_key}"
      request["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
      request.body = multipart_body

      Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: OPEN_TIMEOUT_SECONDS, read_timeout: READ_TIMEOUT_SECONDS) do |http|
        http.request(request)
      end
    end

    def multipart_body
      binary_join(
        field_part("model", model),
        field_part("response_format", "json"),
        file_part,
        "--#{boundary}--\r\n"
      )
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
      filename = file.respond_to?(:original_filename) ? File.basename(file.original_filename.to_s.presence || "mia-voice.webm") : "mia-voice.webm"
      filename = filename.gsub(/["\r\n]/, "_")
      content_type = file.respond_to?(:content_type) ? file.content_type.to_s.presence || "application/octet-stream" : "application/octet-stream"
      contents = File.binread(file.tempfile.path)

      binary_join(
        "--#{boundary}\r\n",
        "Content-Disposition: form-data; name=\"file\"; filename=\"#{filename}\"\r\n",
        "Content-Type: #{content_type}\r\n\r\n",
        contents,
        "\r\n"
      )
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
