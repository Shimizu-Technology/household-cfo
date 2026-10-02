# frozen_string_literal: true

require "test_helper"

class ContentSourcesSecureUrlIntakeTest < ActiveSupport::TestCase
  test "URL cipher uses authenticated encryption and a separate stable identity" do
    url = "https://example.com/private-guide?cohort=one"
    first = ContentSources::UrlCipher.encrypt(url)
    second = ContentSources::UrlCipher.encrypt(url)

    assert_equal url, ContentSources::UrlCipher.decrypt(first)
    refute_equal first.fetch(:ciphertext), second.fetch(:ciphertext)
    assert_equal ContentSources::UrlCipher.identity(url), ContentSources::UrlCipher.identity(url)
    refute_includes first.values.join(" "), url

    tampered = first.merge(ciphertext: Base64.strict_encode64("tampered"))
    assert_raises(ContentSources::UrlCipher::DecryptionError) { ContentSources::UrlCipher.decrypt(tampered) }
  end

  test "URL validator accepts only ASCII DNS HTTPS addresses on port 443" do
    assert_equal "https://example.com/guide?q=1", ContentSources::UrlValidator.normalize!("https://EXAMPLE.com/guide?q=1")

    %w[
      http://example.com/guide
      https://example.com:8443/guide
      https://user:secret@example.com/guide
      https://127.0.0.1/guide
      https://[::1]/guide
      https://localhost/guide
      https://example.com/guide#section
    ].each do |value|
      assert_raises(ContentSources::Error, value) { ContentSources::UrlValidator.normalize!(value) }
    end
    assert_raises(ContentSources::Error) { ContentSources::UrlValidator.normalize!("https://exämple.com/guide") }
    assert_raises(ContentSources::Error) { ContentSources::UrlValidator.normalize!("https://example.com\\@127.0.0.1/") }
  end

  test "DNS resolver rejects a hostname if any answer is nonpublic" do
    resolver = ContentSources::PublicDnsResolver.new
    with_singleton_method(Resolv, :getaddresses, ->(*) { [ "93.184.216.34" ] }) do
      assert_equal [ "93.184.216.34" ], resolver.resolve!("example.com")
    end
    with_singleton_method(Resolv, :getaddresses, ->(*) { [ "93.184.216.34", "127.0.0.1" ] }) do
      error = assert_raises(ContentSources::Error) { resolver.resolve!("example.com") }
      assert_equal "url_host_private", error.code
    end
    with_singleton_method(Resolv, :getaddresses, ->(*) { [ "169.254.169.254" ] }) do
      assert_raises(ContentSources::Error) { resolver.resolve!("metadata.example") }
    end
    with_singleton_method(Resolv, :getaddresses, ->(*) { [ "fc00::1" ] }) do
      assert_raises(ContentSources::Error) { resolver.resolve!("internal.example") }
    end
  end

  test "HTML extractor removes active and hidden content and keeps readable text" do
    html = <<~HTML
      <html><head><style>.secret { display:none }</style><script>privateCanary()</script></head>
      <body><h1>Household guide</h1><p>Choose one clear next step for the family budget.</p>
      <form><input value="private-field"></form><noscript>hidden fallback</noscript></body></html>
    HTML
    text = ContentSources::HtmlTextExtractor.new.call(html)

    assert_includes text, "Household guide"
    assert_includes text, "Choose one clear next step"
    refute_includes text, "privateCanary"
    refute_includes text, "private-field"
    refute_includes text, "hidden fallback"
  end

  test "HTML extractor rejects entity declarations" do
    error = assert_raises(ContentSources::Error) do
      ContentSources::HtmlTextExtractor.new.call('<!DOCTYPE x [<!ENTITY y SYSTEM "file:///etc/passwd">]><body>&y;</body>')
    end
    assert_equal "html_unsafe", error.code
  end

  test "HTTPS fetcher pins the validated address and requests only the primary document" do
    resolver = Object.new
    resolver.define_singleton_method(:resolve!) { |_host| [ "93.184.216.34" ] }
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.add_field("Content-Type", "text/plain")
    response.add_field("Content-Length", "45")
    response.define_singleton_method(:read_body) { |&block| block.call("Choose one clear next step for the household.\n") }
    http = Object.new
    class << http
      attr_accessor :ipaddr, :use_ssl, :verify_mode, :min_version, :open_timeout, :read_timeout, :write_timeout,
        :captured_request
    end
    http.define_singleton_method(:start) { |&block| block.call(http) }
    http.define_singleton_method(:request) do |request, &block|
      self.captured_request = request
      block.call(response)
    end
    tempfile = Tempfile.new([ "pinned-fetcher", ".txt" ])
    tempfile.close

    with_singleton_method(Net::HTTP, :new, ->(*) { http }) do
      result = ContentSources::PinnedHttpsFetcher.new(resolver: resolver).call(
        "https://example.com/guide", output_path: tempfile.path
      )
      assert_equal "93.184.216.34", http.ipaddr
      assert_equal true, http.use_ssl
      assert_equal OpenSSL::SSL::VERIFY_PEER, http.verify_mode
      assert_equal OpenSSL::SSL::TLS1_2_VERSION, http.min_version
      assert_equal "identity", http.captured_request["Accept-Encoding"]
      assert_nil http.captured_request["Cookie"]
      assert_nil http.captured_request["Authorization"]
      assert_equal "text/plain", result.content_type
      assert_equal Digest::SHA256.file(tempfile.path).hexdigest, result.checksum_sha256
    end
  ensure
    tempfile&.unlink
  end

  private

  def with_singleton_method(target, name, implementation)
    original = target.method(name)
    target.define_singleton_method(name, implementation)
    yield
  ensure
    target.define_singleton_method(name, original)
  end
end
