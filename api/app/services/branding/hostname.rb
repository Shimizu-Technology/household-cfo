# frozen_string_literal: true

require "uri"

module Branding
  module Hostname
    LOCAL = %w[localhost 127.0.0.1 ::1].freeze
    LEGACY = %w[householdcfomethod.com www.householdcfomethod.com household-cfo.netlify.app].freeze

    module_function

    def normalize(value)
      hostname = value.to_s.strip.downcase
      return hostname if LOCAL.include?(hostname)
      return nil unless hostname.match?(CoachWorkspaceDomain::HOSTNAME_FORMAT)

      hostname
    end

    def legacy?(hostname)
      configured = ENV.fetch("LEGACY_HOUSEHOLD_CFO_HOSTS", "").split(",").map { |item| item.strip.downcase }.reject(&:blank?)
      (LEGACY + configured).include?(hostname)
    end

    def from_origin(value)
      raw = value.to_s.strip
      return nil if raw.blank?

      uri = URI.parse(raw)
      return nil if uri.userinfo.present? || uri.query.present? || uri.fragment.present? || uri.path.present?

      hostname = normalize(uri.host)
      return nil unless hostname
      return hostname if uri.is_a?(URI::HTTPS) && uri.port == 443
      return hostname if !Rails.env.production? && uri.is_a?(URI::HTTP) && LOCAL.include?(hostname)

      nil
    rescue URI::InvalidURIError
      nil
    end
  end
end
