require "uri"

module WorkosBrowserAuth
  class Origins
    DEFAULTS = %w[https://householdcfomethod.com https://www.householdcfomethod.com https://household-cfo.netlify.app].freeze
    LOCAL_HOSTS = %w[localhost 127.0.0.1 ::1].freeze
    SENSITIVE_QUERY = /\A(?:code|state|access_token|refresh_token|invitation_token|authorization_session_id)\z/i

    def self.origin_for(uri)
      host = uri.hostname.to_s.include?(":") ? "[#{uri.hostname}]" : uri.hostname
      default_port = uri.scheme == "https" ? 443 : 80
      "#{uri.scheme}://#{host}#{uri.port == default_port ? "" : ":#{uri.port}"}"
    end

    def self.approved!(value)
      uri = URI.parse(value.to_s)
      raise WorkosAuth::InvalidToken, "Invalid program origin" unless value.is_a?(String) &&
        uri.host.present? && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil? && uri.path.empty? &&
        value == origin_for(uri)
      local = LOCAL_HOSTS.include?(uri.hostname)
      raise WorkosAuth::InvalidToken, "Invalid program origin" if local && Rails.env.production?
      secure = uri.scheme == "https" && uri.port == 443
      raise WorkosAuth::InvalidToken, "Invalid program origin" unless secure || (!Rails.env.production? && local && uri.scheme == "http")
      configured = (ENV["FRONTEND_URLS"].to_s.split(",") + [ ENV["FRONTEND_URL"].to_s ]).map(&:strip)
      # Query fresh records so a disabled branded origin immediately loses session access.
      active_brand = secure && CoachWorkspaceDomain.active.exists?(hostname: uri.hostname)
      raise WorkosAuth::InvalidToken, "Unknown program origin" unless DEFAULTS.include?(value) || configured.include?(value) || active_brand
      value
    rescue URI::InvalidURIError, NoMethodError
      raise WorkosAuth::InvalidToken, "Invalid program origin"
    end

    def self.return_to!(value, origin:)
      value = "/" if value.blank?
      raise WorkosAuth::InvalidToken, "Invalid return destination" unless value.is_a?(String) && value.bytesize <= 2048 &&
        !value.match?(/[\\\x00-\x20]|%5c|%0[ad]/i)
      uri = URI.parse(value)
      raise WorkosAuth::InvalidToken, "Invalid return destination" unless uri.userinfo.nil? &&
        (uri.host.nil? ? value.start_with?("/") && !value.start_with?("//") : origin_for(uri) == origin)
      path = URI::DEFAULT_PARSER.unescape(uri.path)
      raise WorkosAuth::InvalidToken, "Invalid return destination" if path.start_with?("//", "/api/", "/auth/") || path == "/login" || path.include?("\\") || path.split("/").any? { |part| part.in?(%w[. ..]) }
      raise WorkosAuth::InvalidToken, "Invalid return destination" if URI.decode_www_form(uri.query.to_s).any? { |key, _| key.match?(SENSITIVE_QUERY) }
      "#{origin}#{uri.path.presence || "/"}#{uri.query ? "?#{uri.query}" : ""}#{uri.fragment ? "##{uri.fragment}" : ""}"
    rescue URI::InvalidURIError, ArgumentError
      raise WorkosAuth::InvalidToken, "Invalid return destination"
    end
  end
end
