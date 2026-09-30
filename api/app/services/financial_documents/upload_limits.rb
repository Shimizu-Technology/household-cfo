# frozen_string_literal: true

module FinancialDocuments
  module UploadLimits
    INLINE_SOURCE_MAX_BYTES = 12.megabytes
    STRUCTURED_SOURCE_MAX_BYTES = 20.megabytes
    INLINE_EXTENSIONS = %w[.pdf .jpg .jpeg .png .webp .heic .heif].freeze
    INLINE_CONTENT_TYPES = (FinancialDocumentImport::IMAGE_CONTENT_TYPES + FinancialDocumentImport::PDF_CONTENT_TYPES).freeze

    module_function

    def max_bytes(filename:, content_type:)
      extension = File.extname(filename.to_s).downcase
      return INLINE_SOURCE_MAX_BYTES if extension.in?(INLINE_EXTENSIONS)
      return INLINE_SOURCE_MAX_BYTES if content_type.to_s.in?(INLINE_CONTENT_TYPES)

      STRUCTURED_SOURCE_MAX_BYTES
    end

    def validation_error(byte_size:, filename:, content_type:)
      limit = max_bytes(filename: filename, content_type: content_type)
      return if byte_size.to_i <= limit

      "Uploaded file is too large (max #{limit / 1.megabyte} MB for this file type)"
    end
  end
end
