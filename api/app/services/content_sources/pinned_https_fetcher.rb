# frozen_string_literal: true

require "digest"
require "net/http"
require "openssl"
require "tempfile"
require "uri"

module ContentSources
  class PinnedHttpsFetcher
    MAX_REDIRECTS = 3
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 10
    WRITE_TIMEOUT = 5
    Result = Data.define(:path, :filename, :content_type, :byte_size, :checksum_sha256, :redirect_count)

    def initialize(resolver: PublicDnsResolver.new, html_extractor: HtmlTextExtractor.new)
      @resolver = resolver
      @html_extractor = html_extractor
    end

    def call(url, output_path:)
      current = UrlValidator.normalize!(url)
      redirects = 0

      loop do
        uri = URI.parse(current)
        addresses = @resolver.resolve!(uri.host)
        response, body_path = request(uri, addresses.first, output_path: output_path)
        case response
        when Net::HTTPSuccess
          return finalize!(uri, response, body_path, redirects: redirects)
        when Net::HTTPRedirection
          raise Error, "url_too_many_redirects" if redirects >= MAX_REDIRECTS

          location = response["location"].to_s
          raise Error, "url_redirect_invalid" if location.blank?
          current = UrlValidator.normalize!(URI.join(current, location).to_s)
          redirects += 1
        else
          raise Error, "url_response_invalid"
        end
      end
    rescue Timeout::Error, Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError,
      OpenSSL::SSL::SSLError, EOFError
      raise Error, "url_fetch_failed"
    end

    private

    def request(uri, address, output_path:)
      http = Net::HTTP.new(uri.host, 443, nil)
      unless http.respond_to?(:ipaddr=)
        raise Error, "url_intake_unavailable"
      end
      http.ipaddr = address
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.min_version = OpenSSL::SSL::TLS1_2_VERSION
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      http.write_timeout = WRITE_TIMEOUT if http.respond_to?(:write_timeout=)
      request = Net::HTTP::Get.new(uri.request_uri, {
        "Accept" => "text/html, text/plain, application/pdf, application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "Accept-Encoding" => "identity",
        "User-Agent" => "HouseholdCFO-SourceImporter/1.0"
      })
      response = nil
      File.open(output_path, "wb", 0o600) do |file|
        http.start do |connection|
          connection.request(request) do |incoming|
            response = incoming
            if incoming.is_a?(Net::HTTPSuccess)
              encoding = incoming["content-encoding"].to_s.downcase
              raise Error, "url_content_encoding_unsupported" unless encoding.blank? || encoding == "identity"
              limit = response_limit(incoming["content-type"], uri.path)
              declared = Integer(incoming["content-length"], exception: false)
              raise Error, "file_too_large" if declared && declared > limit
              size = 0
              incoming.read_body do |chunk|
                size += chunk.bytesize
                raise Error, "file_too_large" if size > limit
                file.write(chunk)
              end
            end
          end
        end
      end
      [ response, output_path ]
    end

    def response_limit(content_type, path)
      type = content_type.to_s.split(";", 2).first.to_s.downcase
      extension = File.extname(path.to_s).downcase
      return UploadValidator::PDF_MAX_BYTES if type == "application/pdf" || extension == ".pdf"
      if type.in?(UploadValidator::CONTENT_TYPES.fetch(".docx")) || extension == ".docx"
        return UploadValidator::DOCX_MAX_BYTES
      end

      UploadValidator::TEXT_MAX_BYTES
    end

    def finalize!(uri, response, path, redirects:)
      bytes = File.binread(path)
      type = response["content-type"].to_s.split(";", 2).first.to_s.downcase
      fingerprint = Digest::SHA256.hexdigest(bytes)
      filename, content_type = classify(bytes, type, uri.path, fingerprint)
      if content_type == "text/html"
        extracted = @html_extractor.call(bytes)
        File.binwrite(path, extracted)
        bytes = extracted
        fingerprint = Digest::SHA256.hexdigest(bytes)
        filename = "web-source-#{fingerprint.first(12)}.txt"
        content_type = "text/plain"
      end
      UploadValidator.validate_metadata!(
        filename: filename, content_type: content_type, byte_size: bytes.bytesize, checksum_sha256: fingerprint
      )
      UploadValidator.sniff!(path: path, filename: filename)
      Result.new(
        path: path, filename: filename, content_type: content_type, byte_size: bytes.bytesize,
        checksum_sha256: fingerprint, redirect_count: redirects
      )
    end

    def classify(bytes, content_type, path, fingerprint)
      extension = File.extname(path.to_s).downcase
      if bytes.start_with?("%PDF-") && (content_type == "application/pdf" || extension == ".pdf")
        [ "web-source-#{fingerprint.first(12)}.pdf", "application/pdf" ]
      elsif bytes.start_with?("PK\x03\x04".b, "PK\x05\x06".b) &&
          (content_type.in?(UploadValidator::CONTENT_TYPES.fetch(".docx")) || extension == ".docx")
        [ "web-source-#{fingerprint.first(12)}.docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document" ]
      elsif content_type.in?(%w[text/html application/xhtml+xml])
        [ "web-source.html", "text/html" ]
      elsif content_type.in?(%w[text/plain text/markdown text/vtt application/x-subrip]) ||
          extension.in?(%w[.txt .md .vtt .srt])
        [ "web-source-#{fingerprint.first(12)}.txt", "text/plain" ]
      else
        raise Error, "unsupported_format"
      end
    end
  end
end
