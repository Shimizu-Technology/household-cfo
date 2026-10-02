# frozen_string_literal: true

module ContentSources
  class Error < StandardError
    attr_reader :code

    SAFE_MESSAGES = {
      "unsupported_format" => "Choose a PDF, DOCX, TXT, MD, VTT, or SRT file.",
      "file_too_large" => "This source is over the size limit. Split it into smaller files and try again.",
      "signature_mismatch" => "The file contents do not match the selected file type. Export a fresh copy and try again.",
      "invalid_text" => "This text file is not valid UTF-8 or appears to contain binary data. Export it as UTF-8 text and try again.",
      "too_much_text" => "This source contains more than 120,000 characters. Split it into smaller files so nothing is silently omitted.",
      "pdf_invalid" => "This PDF could not be read safely. Export a fresh text-based PDF and try again.",
      "pdf_encrypted" => "This PDF is password protected. Upload an unlocked, text-based copy.",
      "pdf_too_many_pages" => "This PDF has more than 60 pages. Split it into smaller files so every page can be reviewed.",
      "pdf_page_too_long" => "A PDF page contains more than 10,000 characters. Split or simplify the file so nothing is silently omitted.",
      "pdf_no_readable_text" => "No readable text found. Upload a text-based PDF or export the scan with OCR first.",
      "pdf_resource_limit" => "This PDF exceeded the safe processing time or memory limit. Export a simpler text-based PDF and try again.",
      "docx_invalid" => "This Word file could not be read safely. Export a fresh DOCX and try again.",
      "docx_archive_unsafe" => "This Word file contains an unsafe or unusually compressed archive. Export a fresh DOCX and try again.",
      "docx_too_many_entries" => "This Word file contains too many embedded parts. Export a simpler DOCX and try again.",
      "docx_too_large_uncompressed" => "This Word file expands beyond the safe processing limit. Split it into smaller files and try again.",
      "docx_xml_too_large" => "This Word file contains too much document XML. Split it into smaller files and try again.",
      "docx_too_many_paragraphs" => "This Word file contains more than 2,000 paragraphs. Split it into smaller files and try again.",
      "subtitle_invalid" => "This subtitle file could not be read. Export valid VTT or SRT and try again.",
      "subtitle_too_many_cues" => "This subtitle file contains more than 5,000 cues. Split it into smaller files and try again.",
      "storage_unavailable" => "Private storage is temporarily unavailable. Try again in a moment.",
      "upload_expired" => "The private upload expired. Choose the file and try again.",
      "upload_conflict" => "This private upload changed unexpectedly. Choose the file and try again.",
      "source_quota_reached" => "Your private source library is at its 100-source or 512 MB limit. Delete a private source file before uploading another.",
      "upload_limit_reached" => "Five private uploads are already in progress. Let one finish or expire before starting another.",
      "upload_rate_limited" => "Ten new private uploads were started in the last 15 minutes. Wait a few minutes before starting another.",
      "proposal_unavailable" => "Candidate generation is temporarily unavailable. Retry this source in a moment.",
      "proposal_invalid" => "Candidate generation returned an invalid result. Retry the source or create the guidance manually.",
      "proposal_limit" => "Candidate generation exceeded the safe result limit. Split the source into smaller files and try again.",
      "source_deleted" => "This private source has been deleted.",
      "processing_failed" => "This source could not be processed safely. Check the file and try again.",
      "url_invalid" => "Enter a complete HTTPS address without a fragment or embedded credentials.",
      "url_https_required" => "Only HTTPS source addresses are supported.",
      "url_port_invalid" => "Source addresses must use the standard HTTPS port.",
      "url_host_invalid" => "This source address does not use a supported public hostname.",
      "url_host_unresolved" => "The source hostname could not be resolved. Check the address and try again.",
      "url_host_private" => "This source address does not resolve exclusively to public internet addresses.",
      "url_redirect_invalid" => "The source redirected to an address that cannot be fetched safely.",
      "url_too_many_redirects" => "The source redirected too many times. Use its final HTTPS address instead.",
      "url_fetch_failed" => "The source could not be fetched safely. Check that it is public and try again.",
      "url_response_invalid" => "The source returned an unsupported response.",
      "url_content_encoding_unsupported" => "The source uses an unsupported transfer encoding.",
      "html_unsafe" => "This web page contains document features that cannot be imported safely.",
      "html_invalid" => "This web page could not be read safely.",
      "html_no_readable_text" => "No readable article text was found on this web page.",
      "url_intake_conflict" => "This source request changed unexpectedly. Start a new import.",
      "url_intake_disabled" => "Secure URL intake is not enabled for this Household CFO environment.",
      "url_intake_unavailable" => "Secure URL intake is temporarily unavailable. Try again shortly.",
      "url_staging_cleanup_failed" => "The source is ready, but temporary private storage cleanup needs an administrator retry."
    }.freeze

    def initialize(code)
      @code = code
      super(SAFE_MESSAGES.fetch(code, SAFE_MESSAGES.fetch("processing_failed")))
    end
  end
end
