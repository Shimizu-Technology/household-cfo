# frozen_string_literal: true

# Runs inside ContentSources::PdfSandbox (a separate process with wall-clock,
# CPU and memory limits) so a hostile financial PDF can only exhaust this
# worker, never the web process. It repeats the parse the extractor is about
# to do in-process and prints one small JSON object -- never page text.
#
#   structure: CombinePDF load + page count (batch splitting, page coverage)
#   text:      PDF::Reader text runs on every page (native statement parser)

require "json"
begin
  require "combine_pdf"
  require "pdf/reader"
rescue LoadError
  STDOUT.write(JSON.generate(ok: false, code: "pdf_probe_unavailable"))
  exit
end

class WorkerLimitError < StandardError
  attr_reader :code
  def initialize(code) = (@code = code; super(code))
end

path = ARGV.fetch(0)
mode = ARGV.fetch(1, "structure")
max_pages = Integer(ARGV.fetch(2, "60"), 10)
max_runs = Integer(ARGV.fetch(3, "60000"), 10)

begin
  case mode
  when "structure"
    page_count = CombinePDF.load(path).pages.count
    STDOUT.write(JSON.generate(ok: true, page_count: page_count))
  when "text"
    reader = PDF::Reader.new(path)
    page_count = reader.page_count
    raise WorkerLimitError, "pdf_too_many_pages" unless page_count.between?(1, max_pages)

    run_count = 0
    reader.pages.each do |page|
      run_count += page.runs.length
      raise WorkerLimitError, "pdf_too_much_text" if run_count > max_runs
    end
    STDOUT.write(JSON.generate(ok: true, page_count: page_count, run_count: run_count))
  else
    raise WorkerLimitError, "pdf_probe_mode_invalid"
  end
rescue CombinePDF::EncryptionError, PDF::Reader::EncryptedPDFError
  STDOUT.write(JSON.generate(ok: false, code: "pdf_encrypted"))
rescue WorkerLimitError => error
  STDOUT.write(JSON.generate(ok: false, code: error.code))
rescue StandardError
  STDOUT.write(JSON.generate(ok: false, code: "pdf_invalid"))
end
