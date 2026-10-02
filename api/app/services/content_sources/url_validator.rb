# frozen_string_literal: true

require "uri"
require "ipaddr"

module ContentSources
  class UrlValidator
    MAX_URL_BYTES = 2_048

    class << self
      def normalize!(value)
        raw = value.to_s.strip
        raise Error, "url_invalid" if raw.blank? || raw.bytesize > MAX_URL_BYTES
        raise Error, "url_invalid" unless raw.ascii_only? && !raw.match?(/[\x00-\x20\x7f\\]/)

        uri = URI.parse(raw)
        raise Error, "url_https_required" unless uri.is_a?(URI::HTTPS) && uri.scheme == "https"
        raise Error, "url_invalid" if uri.userinfo.present? || uri.fragment.present?
        raise Error, "url_port_invalid" unless uri.port == 443

        host = uri.host.to_s.downcase
        raise Error, "url_host_invalid" unless valid_dns_name?(host)
        raise Error, "url_host_invalid" if ip_literal?(host)

        uri.host = host
        uri.path = "/" if uri.path.blank?
        uri.to_s
      rescue URI::InvalidURIError
        raise Error, "url_invalid"
      end

      private

      def valid_dns_name?(host)
        return false if host.blank? || host.bytesize > 253 || !host.ascii_only? || host.end_with?(".")

        labels = host.split(".")
        labels.length >= 2 && labels.all? do |label|
          label.bytesize.between?(1, 63) && label.match?(/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/)
        end
      end

      def ip_literal?(host)
        IPAddr.new(host)
        true
      rescue IPAddr::InvalidAddressError
        false
      end
    end
  end
end
