# frozen_string_literal: true

module FinancialDocuments
  # Bounds every participant financial file before an in-process parser
  # touches it. In production Solid Queue runs inside the Puma web process, so
  # an oversized download, a zip bomb or a pathological PDF must fail the one
  # import calmly instead of exhausting the API for everyone.
  module SourceSafety
    MESSAGE = "We couldn't read this file safely. Try a smaller file, a CSV export, or a screenshot."

    # DOCX/XLSX. Roo extracts every workbook part to disk and parses sheets
    # as DOM, so the expanded total matters more than the upload size. 50 MB
    # of XML is several times the 250,000 cells SpreadsheetSummarizer scans.
    OOXML_MAX_ENTRIES = 1_000
    OOXML_MAX_UNCOMPRESSED_BYTES = 50.megabytes
    OOXML_MAX_COMPRESSION_RATIO = 200
    OOXML_RATIO_FLOOR_BYTES = 1.megabyte
    OOXML_MAX_XML_BYTES = 5.megabytes

    # PDFs are parsed first in ContentSources::PdfSandbox's child process.
    PDF_PROBE_SCRIPT = "lib/content_sources/pdf_probe_worker.rb"
    PDF_PROBE_TIMEOUT_SECONDS = 20
    PDF_PROBE_CPU_SECONDS = 12
    PDF_PROBE_GEMS = %w[combine_pdf pdf-reader].freeze

    class Unreadable < StandardError
      attr_reader :reason

      def initialize(reason)
        @reason = reason
        super(MESSAGE)
      end
    end

    module_function

    def check_ooxml!(path)
      ooxml_guard.check!(path)
    rescue FileSafety::OoxmlGuard::Error => e
      raise Unreadable, "ooxml_#{e.code}"
    end

    def check_ooxml_entries!(entries)
      ooxml_guard.check_entries!(entries)
    rescue FileSafety::OoxmlGuard::Error => e
      raise Unreadable, "ooxml_#{e.code}"
    end

    # Returns nil when the entry is missing.
    def read_ooxml_xml(zip, name)
      xml = FileSafety::OoxmlGuard.read_entry!(zip, name, max_bytes: OOXML_MAX_XML_BYTES)
      FileSafety::OoxmlGuard.check_xml!(xml)
      xml
    rescue FileSafety::OoxmlGuard::Error => e
      return if e.code == "missing_entry"

      raise Unreadable, "ooxml_#{e.code}"
    end

    # Streams a private source into io, aborting as soon as it passes
    # max_bytes. Returns false when storage could not serve the object.
    def download(key, io, max_bytes:)
      io.define_singleton_method(:write) do |*chunks|
        raise Unreadable, "source_too_large" if pos + chunks.sum(&:bytesize) > max_bytes

        super(*chunks)
      end
      return false unless S3Service.download_to_io(key, io)
      raise Unreadable, "source_too_large" if io.size > max_bytes

      true
    end

    # Loads the PDF structure in the sandbox and returns its page count.
    # Raises Unreadable (reason pdf_encrypted / pdf_invalid / pdf_*) instead.
    def pdf_page_count!(path)
      raise Unreadable, "source_too_large" if File.size(path) > UploadLimits::INLINE_SOURCE_MAX_BYTES

      Integer(pdf_sandbox.run(path, "structure").fetch("page_count"))
    rescue ContentSources::Error => e
      raise Unreadable, e.code
    rescue KeyError, ArgumentError, TypeError
      raise Unreadable, "pdf_invalid"
    end

    # True only when PDF::Reader can read every page's text within the
    # sandbox limits. The native statement parser is an optional fast path,
    # so any failure here just routes the PDF to the regular extraction path.
    def pdf_text_readable?(path, max_pages:, max_runs:)
      return false if File.size(path) > UploadLimits::INLINE_SOURCE_MAX_BYTES

      pdf_sandbox.run(path, "text", max_pages, max_runs)["ok"] == true
    rescue ContentSources::Error
      false
    end

    def ooxml_guard
      FileSafety::OoxmlGuard.new(
        max_file_bytes: UploadLimits::STRUCTURED_SOURCE_MAX_BYTES,
        max_entries: OOXML_MAX_ENTRIES,
        max_uncompressed: OOXML_MAX_UNCOMPRESSED_BYTES,
        max_ratio: OOXML_MAX_COMPRESSION_RATIO,
        ratio_floor_bytes: OOXML_RATIO_FLOOR_BYTES
      )
    end

    def pdf_sandbox
      ContentSources::PdfSandbox.new(
        script_path: Rails.root.join(PDF_PROBE_SCRIPT),
        timeout_seconds: PDF_PROBE_TIMEOUT_SECONDS,
        cpu_seconds: PDF_PROBE_CPU_SECONDS,
        load_paths: pdf_probe_load_paths
      )
    end

    # The exact require paths of the PDF gems (and their dependencies) this
    # process already loaded from Gemfile.lock.
    def pdf_probe_load_paths
      specs = {}
      pending = PDF_PROBE_GEMS.dup
      while (name = pending.pop)
        spec = Gem.loaded_specs[name]
        next if spec.nil? || specs.key?(name)

        specs[name] = spec
        pending.concat(spec.runtime_dependencies.map(&:name))
      end
      specs.values.flat_map(&:full_require_paths).uniq
    end
  end
end
