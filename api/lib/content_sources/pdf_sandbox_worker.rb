# frozen_string_literal: true

require "json"
require "pdf/reader"

MAX_PAGES = 60
MAX_PAGE_CHARS = 10_000
MAX_TOTAL_CHARS = 120_000
class WorkerLimitError < StandardError
  attr_reader :code
  def initialize(code) = (@code = code; super(code))
end

begin
  reader = PDF::Reader.new(ARGV.fetch(0))
  raise WorkerLimitError, "pdf_too_many_pages" if reader.page_count > MAX_PAGES

  total = 0
  pages = reader.pages.map do |page|
    text = page.text.to_s
    raise WorkerLimitError, "pdf_page_too_long" if text.length > MAX_PAGE_CHARS
    total += text.length
    raise WorkerLimitError, "too_much_text" if total > MAX_TOTAL_CHARS
    text
  end
  STDOUT.write(JSON.generate(ok: true, page_count: reader.page_count, pages: pages))
rescue PDF::Reader::EncryptedPDFError
  STDOUT.write(JSON.generate(ok: false, code: "pdf_encrypted"))
rescue PDF::Reader::MalformedPDFError, PDF::Reader::UnsupportedFeatureError
  STDOUT.write(JSON.generate(ok: false, code: "pdf_invalid"))
rescue WorkerLimitError => error
  STDOUT.write(JSON.generate(ok: false, code: error.code))
rescue StandardError
  STDOUT.write(JSON.generate(ok: false, code: "pdf_invalid"))
end
