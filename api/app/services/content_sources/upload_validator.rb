# frozen_string_literal: true

module ContentSources
  class UploadValidator
    PDF_MAX_BYTES = 12 * 1024 * 1024
    DOCX_MAX_BYTES = 10 * 1024 * 1024
    TEXT_MAX_BYTES = 2 * 1024 * 1024
    EXTENSIONS = %w[.pdf .docx .txt .md .vtt .srt].freeze
    CONTENT_TYPES = {
      ".pdf" => %w[application/pdf],
      ".docx" => %w[application/vnd.openxmlformats-officedocument.wordprocessingml.document application/zip],
      ".txt" => %w[text/plain],
      ".md" => %w[text/markdown text/plain],
      ".vtt" => %w[text/vtt text/plain],
      ".srt" => %w[application/x-subrip text/plain]
    }.freeze

    class << self
      def validate_metadata!(filename:, content_type:, byte_size:, checksum_sha256:)
        extension = File.extname(filename.to_s).downcase
        raise Error, "unsupported_format" unless extension.in?(EXTENSIONS)
        raise Error, "unsupported_format" unless content_type.to_s.in?(CONTENT_TYPES.fetch(extension))
        size = Integer(byte_size, exception: false)
        raise Error, "file_too_large" unless size&.positive? && size <= max_bytes(extension)
        raise Error, "signature_mismatch" unless checksum_sha256.to_s.match?(/\A[0-9a-f]{64}\z/)

        true
      end

      def sniff!(path:, filename:)
        extension = File.extname(filename.to_s).downcase
        signature = File.binread(path, 8)
        case extension
        when ".pdf"
          raise Error, "signature_mismatch" unless signature.start_with?("%PDF-")
        when ".docx"
          raise Error, "signature_mismatch" unless signature.start_with?("PK\x03\x04".b, "PK\x05\x06".b)
        else
          validate_text_bytes!(File.binread(path), extension: extension)
        end
        true
      rescue Errno::ENOENT, EOFError
        raise Error, "signature_mismatch"
      end

      def validate_text_bytes!(bytes, extension:)
        raise Error, "invalid_text" if bytes.include?("\x00".b)

        text = bytes.dup
        text = text.byteslice(3..) if text.start_with?("\xEF\xBB\xBF".b)
        text.force_encoding(Encoding::UTF_8)
        raise Error, "invalid_text" unless text.valid_encoding?
        control_count = text.each_codepoint.count { |code| code < 32 && !code.in?([ 9, 10, 13 ]) }
        raise Error, "invalid_text" if control_count > [ text.length / 100, 4 ].max
        raise Error, "subtitle_invalid" if extension == ".vtt" && !text.sub(/\A\uFEFF/, "").lstrip.start_with?("WEBVTT")
        if extension == ".srt" && text.present? && !text.match?(/(?:\A|\n)\s*\d+\s*\n\s*\d{2}:\d{2}:\d{2}[,.]\d{3}\s*-->\s*\d{2}:\d{2}:\d{2}[,.]\d{3}/)
          raise Error, "subtitle_invalid"
        end
        true
      end

      def max_bytes(extension)
        case extension
        when ".pdf" then PDF_MAX_BYTES
        when ".docx" then DOCX_MAX_BYTES
        else TEXT_MAX_BYTES
        end
      end
    end
  end
end
