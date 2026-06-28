# frozen_string_literal: true

module FinancialDocuments
  class SourcePreviewer
    MAX_TEXT_LENGTH = 12_000

    Result = Struct.new(:ok, :data, :error, keyword_init: true) do
      def success?
        ok
      end
    end

    def initialize(document_import)
      @document_import = document_import
    end

    def call
      return failure("Preview is not available for this file type") unless previewable?

      Tempfile.create([ "financial-document-source-preview", file_extension ]) do |file|
        file.binmode
        return failure("Could not load private document source") unless S3Service.download_to_io(document_import.s3_key, file)

        file.rewind
        return spreadsheet_preview(file.path) if document_import.spreadsheet?
        return word_preview(file.path) if document_import.word_document?
      end

      failure("Preview is not available for this file type")
    rescue StandardError => e
      Rails.logger.warn("[FinancialDocuments::SourcePreviewer] import #{document_import.id} preview failed: #{e.class}: #{e.message}")
      failure("Could not build a safe preview for this document")
    end

    private

    attr_reader :document_import

    def previewable?
      document_import.spreadsheet? || document_import.word_document?
    end

    def spreadsheet_preview(file_path)
      summary = SpreadsheetSummarizer.new(file_path: file_path, filename: document_import.filename).call
      success(summary.merge(type: "spreadsheet", content_type: document_import.content_type))
    end

    def word_preview(file_path)
      summary = DocxSummarizer.new(file_path: file_path, filename: document_import.filename).call
      success(
        type: "text",
        filename: document_import.filename,
        content_type: document_import.content_type,
        text: summary.fetch(:text, "").truncate(MAX_TEXT_LENGTH, omission: "…")
      )
    end

    def file_extension
      File.extname(document_import.filename.to_s).presence || ".bin"
    end

    def success(data)
      Result.new(ok: true, data: data, error: nil)
    end

    def failure(error)
      Result.new(ok: false, data: nil, error: error)
    end
  end
end
