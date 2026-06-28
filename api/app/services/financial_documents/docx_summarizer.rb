# frozen_string_literal: true

require "nokogiri"
require "zip"

module FinancialDocuments
  class DocxSummarizer
    MAX_PARAGRAPHS = 80
    MAX_TEXT_LENGTH = 12_000
    MAX_PARAGRAPH_LENGTH = 500

    def initialize(file_path:, filename:)
      @file_path = file_path
      @filename = filename
    end

    def call
      {
        filename: filename,
        text: document_text.truncate(MAX_TEXT_LENGTH, omission: "…")
      }
    end

    private

    attr_reader :file_path, :filename

    def document_text
      xml = Zip::File.open(file_path) { |zip| zip.find_entry("word/document.xml")&.get_input_stream&.read }
      return "" if xml.blank?

      doc = Nokogiri::XML(xml) { |config| config.strict.nonet }
      doc.remove_namespaces!
      paragraphs = doc.xpath("//p").filter_map do |paragraph|
        clean_text(paragraph.xpath(".//t").map(&:text).join).presence
      end

      paragraphs.first(MAX_PARAGRAPHS).join("\n")
    rescue Zip::Error, Nokogiri::XML::SyntaxError
      ""
    end

    def clean_text(value)
      value.to_s
        .unicode_normalize(:nfkc)
        .gsub(/[[:cntrl:]]/, " ")
        .gsub(/[<>`]/, "")
        .squish
        .truncate(MAX_PARAGRAPH_LENGTH, omission: "…")
    end
  end
end
