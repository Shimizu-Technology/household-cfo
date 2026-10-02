# frozen_string_literal: true

require "ipaddr"
require "resolv"

module ContentSources
  class PublicDnsResolver
    BLOCKED_RANGES = %w[
      0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16
      172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.168.0.0/16 198.18.0.0/15
      198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4
      ::/128 ::1/128 ::ffff:0:0/96 64:ff9b::/96 100::/64 2001:db8::/32
      2001:10::/28 fc00::/7 fe80::/10 ff00::/8
    ].map { |range| IPAddr.new(range) }.freeze

    def resolve!(hostname)
      addresses = Resolv.getaddresses(hostname.to_s).uniq
      raise Error, "url_host_unresolved" if addresses.empty?

      parsed = addresses.map { |address| IPAddr.new(address) }
      raise Error, "url_host_private" unless parsed.all? { |address| public_address?(address) }

      parsed.map(&:to_s)
    rescue Resolv::ResolvError, IPAddr::InvalidAddressError
      raise Error, "url_host_unresolved"
    end

    private

    def public_address?(address)
      BLOCKED_RANGES.none? { |range| range.include?(address) }
    end
  end
end
