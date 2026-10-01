# frozen_string_literal: true

require "nokogiri"
require "pdf/reader"
require "zip"

module ContentSources
  class Parser
    MAX_CHARS = 120_000
    MAX_SEGMENT_CHARS = 20_000
    MAX_SEGMENTS = 6
    MAX_PDF_PAGES = 60
    MAX_PDF_PAGE_CHARS = 10_000
    MAX_DOCX_ENTRIES = 200
    MAX_DOCX_UNCOMPRESSED_BYTES = 25 * 1024 * 1024
    MAX_DOCX_XML_BYTES = 5 * 1024 * 1024
    MAX_DOCX_PARAGRAPHS = 2_000
    MAX_ZIP_COMPRESSION_RATIO = 100
    MAX_SUBTITLE_CUES = 5_000

    Segment = Data.define(:number, :text, :locator)
    Result = Data.define(:segments, :metadata)
    Piece = Data.define(:text, :locator)

    def call(path:, filename:)
      UploadValidator.sniff!(path: path, filename: filename)
      extension = File.extname(filename.to_s).downcase
      pieces, metadata = case extension
      when ".pdf" then pdf_pieces(path)
      when ".docx" then docx_pieces(path)
      when ".vtt", ".srt" then subtitle_pieces(path, extension)
      else text_pieces(path)
      end
      normalized_size = pieces.sum { |piece| piece.text.length }
      raise Error, "too_much_text" if normalized_size > MAX_CHARS

      segments = segment(pieces)
      raise Error, "too_much_text" if segments.length > MAX_SEGMENTS

      Result.new(segments: segments, metadata: metadata.merge(character_count: normalized_size, segment_count: segments.length))
    rescue PDF::Reader::EncryptedPDFError
      raise Error, "pdf_encrypted"
    rescue PDF::Reader::MalformedPDFError, PDF::Reader::UnsupportedFeatureError
      raise Error, "pdf_invalid"
    rescue Zip::Error, Nokogiri::XML::SyntaxError
      raise Error, "docx_invalid"
    end

    private

    def pdf_pieces(path)
      payload = PdfSandbox.new.call(path)
      raise Error, "pdf_too_many_pages" if payload.fetch("page_count") > MAX_PDF_PAGES

      pieces = payload.fetch("pages").each_with_index.filter_map do |page_text, index|
        text = normalize_text(page_text)
        raise Error, "pdf_page_too_long" if text.length > MAX_PDF_PAGE_CHARS
        Piece.new(text: text, locator: { "type" => "pdf", "page_start" => index + 1, "page_end" => index + 1 }) if text.present?
      end
      raise Error, "pdf_no_readable_text" if pieces.empty? || pieces.sum { |piece| piece.text.scan(/[[:alnum:]]/).length } < 20

      [ pieces, { format: "pdf", page_count: payload.fetch("page_count") } ]
    end

    def docx_pieces(path)
      paragraphs = nil
      Zip::File.open(path) do |zip|
        entries = zip.entries
        raise Error, "docx_too_many_entries" if entries.length > MAX_DOCX_ENTRIES
        validate_zip_entries!(entries)
        names = entries.map(&:name)
        raise Error, "docx_invalid" unless names.include?("[Content_Types].xml") && names.include?("word/document.xml")
        raise Error, "docx_archive_unsafe" if names.any? { |name| name.downcase.end_with?("vbaproject.bin") }

        content_types = bounded_entry_read!(zip, "[Content_Types].xml", max_bytes: 512 * 1024)
        raise Error, "docx_archive_unsafe" if content_types.match?(/macroEnabled|vnd\.ms-word\.document\.macroEnabled/i)
        document_xml = bounded_entry_read!(zip, "word/document.xml", max_bytes: MAX_DOCX_XML_BYTES, error_code: "docx_xml_too_large")
        validate_xml_safety!(document_xml)
        validate_external_relationships!(zip)

        document = Nokogiri::XML(document_xml) { |config| config.strict.nonet }
        raise Error, "docx_archive_unsafe" if document.internal_subset
        document.remove_namespaces!
        paragraph_nodes = document.xpath("//p")
        raise Error, "docx_too_many_paragraphs" if paragraph_nodes.length > MAX_DOCX_PARAGRAPHS
        paragraphs = paragraph_nodes.each_with_index.filter_map do |paragraph, index|
          text = normalize_text(paragraph.xpath(".//t").map(&:text).join)
          Piece.new(text: text, locator: { "type" => "docx", "paragraph_start" => index + 1, "paragraph_end" => index + 1 }) if text.present?
        end
      end
      raise Error, "docx_invalid" if paragraphs.blank?

      [ paragraphs, { format: "docx", paragraph_count: paragraphs.length } ]
    end

    def validate_zip_entries!(entries)
      total = 0
      entries.each do |entry|
        name = entry.name.to_s
        unsafe_name = name.start_with?("/", "\\") || name.split(/[\\\/]/).include?("..") || name.include?("\0")
        raise Error, "docx_archive_unsafe" if unsafe_name || (entry.respond_to?(:encrypted?) && entry.encrypted?)
        total += entry.size
        raise Error, "docx_too_large_uncompressed" if total > MAX_DOCX_UNCOMPRESSED_BYTES
        if entry.size.positive? && (entry.compressed_size.to_i.zero? || entry.size.to_f / entry.compressed_size > MAX_ZIP_COMPRESSION_RATIO)
          raise Error, "docx_archive_unsafe"
        end
      end
    end

    def bounded_entry_read!(zip, name, max_bytes:, error_code: "docx_archive_unsafe")
      entry = zip.find_entry(name)
      raise Error, "docx_invalid" unless entry
      raise Error, error_code if entry.size > max_bytes

      entry.get_input_stream.read(max_bytes + 1).tap { |value| raise Error, error_code if value.bytesize > max_bytes }
    end

    def validate_xml_safety!(xml)
      scan = xml.to_s
      if scan.include?("\0")
        encoding = scan.start_with?("\xFE\xFF".b) ? Encoding::UTF_16BE : Encoding::UTF_16LE
        scan = scan.dup.force_encoding(encoding).encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
      end
      raise Error, "docx_archive_unsafe" if scan.match?(/<!DOCTYPE|<!ENTITY/i)
    end

    def validate_external_relationships!(zip)
      zip.entries.select { |entry| entry.name.end_with?(".rels") }.each do |entry|
        xml = bounded_entry_read!(zip, entry.name, max_bytes: 512 * 1024)
        validate_xml_safety!(xml)
        document = Nokogiri::XML(xml) { |config| config.strict.nonet }
        raise Error, "docx_archive_unsafe" if document.internal_subset
        raise Error, "docx_archive_unsafe" if document.xpath("//*[local-name()='Relationship'][translate(@TargetMode, 'EXTERNAL', 'external')='external']").any?
      end
    end

    def text_pieces(path)
      bytes = File.binread(path)
      UploadValidator.validate_text_bytes!(bytes, extension: File.extname(path).downcase)
      text = decode_text(bytes)
      raise Error, "too_much_text" if text.length > MAX_CHARS
      pieces = text.lines.each_with_index.filter_map do |line, index|
        value = normalize_text(line)
        Piece.new(text: value, locator: { "type" => "text", "line_start" => index + 1, "line_end" => index + 1 }) if value.present?
      end
      raise Error, "invalid_text" if pieces.empty?

      [ pieces, { format: "text", line_count: text.lines.length } ]
    end

    def subtitle_pieces(path, extension)
      bytes = File.binread(path)
      UploadValidator.validate_text_bytes!(bytes, extension: extension)
      text = decode_text(bytes)
      cues = extension == ".vtt" ? parse_vtt(text) : parse_srt(text)
      raise Error, "subtitle_too_many_cues" if cues.length > MAX_SUBTITLE_CUES
      raise Error, "subtitle_invalid" if cues.empty?

      pieces = cues.each_with_index.map do |cue, index|
        Piece.new(
          text: normalize_text(cue.fetch(:text)),
          locator: {
            "type" => extension.delete_prefix("."),
            "cue_start" => index + 1,
            "cue_end" => index + 1,
            "time_start" => cue.fetch(:start),
            "time_end" => cue.fetch(:finish)
          }
        )
      end
      raise Error, "too_much_text" if pieces.sum { |piece| piece.text.length } > MAX_CHARS

      [ pieces, { format: extension.delete_prefix("."), cue_count: pieces.length } ]
    end

    def parse_vtt(text)
      blocks = text.sub(/\AWEBVTT[^\n]*\n?/i, "").split(/\n{2,}/)
      blocks.filter_map do |block|
        lines = block.lines.map(&:strip).reject(&:blank?)
        next if lines.empty? || lines.first.match?(/\A(?:NOTE|STYLE|REGION)(?:\s|\z)/i)
        timing_index = lines.index { |line| line.include?("-->") }
        raise Error, "subtitle_invalid" unless timing_index && timing_index <= 1
        timing = parse_timing(lines[timing_index], allow_short_hours: true)
        raise Error, "subtitle_invalid" unless timing
        body = lines[(timing_index + 1)..].to_a.join(" ")
        raise Error, "subtitle_invalid" if body.blank?

        { **timing, text: body }
      end
    end

    def parse_srt(text)
      text.split(/\n{2,}/).filter_map do |block|
        lines = block.lines.map(&:strip).reject(&:blank?)
        next if lines.empty?
        timing_index = lines.index { |line| line.include?("-->") }
        raise Error, "subtitle_invalid" unless timing_index && timing_index <= 1
        timing = parse_timing(lines[timing_index], allow_short_hours: false)
        raise Error, "subtitle_invalid" unless timing
        body = lines[(timing_index + 1)..].to_a.join(" ")
        raise Error, "subtitle_invalid" if body.blank?

        { **timing, text: body }
      end
    end

    def parse_timing(value, allow_short_hours:)
      time = allow_short_hours ? /(\d{2}:)?\d{2}:\d{2}[.,]\d{3}/ : /\d{2}:\d{2}:\d{2}[.,]\d{3}/
      match = value.match(/\A(?<start>#{time.source})\s*-->\s*(?<finish>#{time.source})(?:\s+.*)?\z/)
      return unless match
      start_seconds = timestamp_seconds(match[:start])
      finish_seconds = timestamp_seconds(match[:finish])
      return unless start_seconds && finish_seconds && finish_seconds > start_seconds

      { start: match[:start], finish: match[:finish] }
    end

    def timestamp_seconds(value)
      components = value.tr(",", ".").split(":")
      seconds = Float(components.pop, exception: false)
      minutes = Integer(components.pop, exception: false)
      hours = components.empty? ? 0 : Integer(components.pop, exception: false)
      return unless seconds && minutes && hours && seconds < 60 && minutes < 60 && hours >= 0

      (hours * 3600) + (minutes * 60) + seconds
    end

    def decode_text(bytes)
      value = bytes.dup
      value = value.byteslice(3..) if value.start_with?("\xEF\xBB\xBF".b)
      normalize_text(value.force_encoding(Encoding::UTF_8))
    end

    def normalize_text(value)
      value.to_s.unicode_normalize(:nfkc)
        .gsub("\r\n", "\n").gsub("\r", "\n")
        .gsub(/[^\P{C}\n\t]/, " ")
        .lines.map { |line| line.gsub(/[ \t]+/, " ").strip }.join("\n")
        .gsub(/\n{3,}/, "\n\n").strip
    end

    def segment(pieces)
      segments = []
      buffer = +""
      locators = []
      pieces.each do |piece|
        split_piece(piece).each do |part|
          separator = buffer.present? ? "\n\n" : ""
          if buffer.length + separator.length + part.text.length > MAX_SEGMENT_CHARS
            segments << build_segment(segments.length + 1, buffer, locators)
            buffer = +""
            locators = []
            separator = ""
          end
          buffer << separator << part.text
          locators << part.locator
        end
      end
      segments << build_segment(segments.length + 1, buffer, locators) if buffer.present?
      segments
    end

    def split_piece(piece)
      return [ piece ] if piece.text.length <= MAX_SEGMENT_CHARS

      piece.text.scan(/.{1,#{MAX_SEGMENT_CHARS}}/m).map { |text| Piece.new(text: text, locator: piece.locator) }
    end

    def build_segment(number, text, locators)
      first = locators.first || {}
      last = locators.last || first
      locator = { "type" => first["type"], "segment" => number }
      %w[page paragraph line cue].each do |kind|
        start_key = "#{kind}_start"
        end_key = "#{kind}_end"
        locator[start_key] = first[start_key] if first.key?(start_key)
        locator[end_key] = last[end_key] if last.key?(end_key)
      end
      locator["time_start"] = first["time_start"] if first["time_start"]
      locator["time_end"] = last["time_end"] if last["time_end"]
      Segment.new(number: number, text: text, locator: locator)
    end
  end
end
