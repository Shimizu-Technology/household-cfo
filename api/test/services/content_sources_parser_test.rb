# frozen_string_literal: true

require "test_helper"
require "tempfile"
require "zip"

class ContentSourcesParserTest < ActiveSupport::TestCase
  test "parses UTF-8 text deterministically without truncation" do
    with_file(".txt", "First coaching point.\n\nSecond coaching point.\n") do |path|
      result = ContentSources::Parser.new.call(path: path, filename: "guide.txt")

      assert_equal 1, result.segments.length
      assert_includes result.segments.first.text, "First coaching point"
      assert_equal "text", result.segments.first.locator.fetch("type")
      assert_equal 3, result.metadata.fetch(:line_count)
    end
  end

  test "accepts UTF-8 BOM and rejects invalid or oversized text" do
    with_file(".md", "\xEF\xBB\xBF# Heading\nSafe text".b) do |path|
      assert_equal "# Heading\n\nSafe text", ContentSources::Parser.new.call(path: path, filename: "guide.md").segments.first.text
    end
    with_file(".txt", "bad\xFFtext".b) do |path|
      assert_error_code("invalid_text") { ContentSources::Parser.new.call(path: path, filename: "bad.txt") }
    end
    with_file(".txt", "a" * 120_001) do |path|
      assert_error_code("too_much_text") { ContentSources::Parser.new.call(path: path, filename: "large.txt") }
    end
  end

  test "parses VTT and SRT timing with CRLF and enforces cue bounds" do
    vtt = "WEBVTT\r\n\r\n00:01.000 --> 00:03.000\r\nStart with one clear question.\r\n"
    with_file(".vtt", vtt) do |path|
      result = ContentSources::Parser.new.call(path: path, filename: "lesson.vtt")
      assert_equal "00:01.000", result.segments.first.locator.fetch("time_start")
      assert_equal 1, result.metadata.fetch(:cue_count)
    end

    srt = "1\r\n00:00:01,000 --> 00:00:03.500\r\nChoose one next step.\r\n"
    with_file(".srt", srt) do |path|
      result = ContentSources::Parser.new.call(path: path, filename: "lesson.srt")
      assert_equal "00:00:03.500", result.segments.first.locator.fetch("time_end")
    end

    excessive = "WEBVTT\n\n" + 5_001.times.map { |index| "00:00.000 --> 00:01.000\nCue #{index}" }.join("\n\n")
    with_file(".vtt", excessive) do |path|
      assert_error_code("subtitle_too_many_cues") { ContentSources::Parser.new.call(path: path, filename: "long.vtt") }
    end

    mixed = "WEBVTT\n\n00:01.000 --> 00:03.000\nValid cue\n\n00:72.000 --> 00:74.000\nMalformed cue"
    with_file(".vtt", mixed) do |path|
      assert_error_code("subtitle_invalid") { ContentSources::Parser.new.call(path: path, filename: "mixed.vtt") }
    end
  end

  test "rejects unsafe DOCX packages and parses a bounded document" do
    with_docx(paragraphs: [ "First lesson", "Second lesson" ]) do |path|
      result = ContentSources::Parser.new.call(path: path, filename: "lesson.docx")
      assert_equal 2, result.metadata.fetch(:paragraph_count)
      assert_includes result.segments.first.text, "Second lesson"
    end

    with_docx(paragraphs: [ "Unsafe" ], extra_entries: { "../private.txt" => "secret" }) do |path|
      assert_error_code("docx_archive_unsafe") { ContentSources::Parser.new.call(path: path, filename: "unsafe.docx") }
    end

    with_docx(paragraphs: [ "Unsafe" ], document_prefix: '<!DOCTYPE x [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>') do |path|
      assert_error_code("docx_archive_unsafe") { ContentSources::Parser.new.call(path: path, filename: "unsafe.docx") }
    end

    with_docx(paragraphs: [ "Unsafe" ], external_relationship: true) do |path|
      assert_error_code("docx_archive_unsafe") { ContentSources::Parser.new.call(path: path, filename: "unsafe.docx") }
    end

    utf16_doctype = %(<?xml version="1.0" encoding="UTF-16"?><!DOCTYPE x [<!ENTITY xxe SYSTEM "file:///etc/passwd">]><x/>).encode(Encoding::UTF_16LE)
    assert_error_code("docx_archive_unsafe") { ContentSources::Parser.new.send(:validate_xml_safety!, "\xFF\xFE".b + utf16_doctype.b) }
  end

  test "rejects blank scanned PDFs and files over the page cap" do
    with_pdf_pages(1) do |path|
      assert_error_code("pdf_no_readable_text") { ContentSources::Parser.new.call(path: path, filename: "scan.pdf") }
    end
    with_pdf_pages(61) do |path|
      assert_error_code("pdf_too_many_pages") { ContentSources::Parser.new.call(path: path, filename: "long.pdf") }
    end
  end

  private

  def with_file(extension, content)
    file = Tempfile.new([ "content-source", extension ])
    file.binmode
    file.write(content)
    file.close
    yield file.path
  ensure
    file&.close!
  end

  def with_docx(paragraphs:, extra_entries: {}, document_prefix: "", external_relationship: false)
    file = Tempfile.new([ "content-source", ".docx" ])
    file.close
    Zip::OutputStream.open(file.path) do |zip|
      zip.put_next_entry("[Content_Types].xml")
      zip.write('<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>')
      zip.put_next_entry("word/document.xml")
      body = paragraphs.map { |text| "<w:p><w:r><w:t>#{text}</w:t></w:r></w:p>" }.join
      zip.write(%(#{document_prefix}<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>#{body}</w:body></w:document>))
      if external_relationship
        zip.put_next_entry("word/_rels/document.xml.rels")
        zip.write('<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="x" Target="https://example.com" TargetMode="External"/></Relationships>')
      end
      extra_entries.each do |name, value|
        zip.put_next_entry(name)
        zip.write(value)
      end
    end
    yield file.path
  ensure
    file&.close!
  end

  def with_pdf_pages(count)
    file = Tempfile.new([ "content-source", ".pdf" ])
    file.close
    pdf = CombinePDF.new
    count.times { pdf << CombinePDF.create_page }
    pdf.save(file.path)
    yield file.path
  ensure
    file&.close!
  end

  def assert_error_code(code)
    error = assert_raises(ContentSources::Error) { yield }
    assert_equal code, error.code
  end
end
