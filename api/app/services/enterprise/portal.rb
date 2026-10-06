module Enterprise
  class Portal
    INTENTS = %w[sso dsync].freeze
    def self.call(organization:, user:, intent:, return_url:, client: Client.new, claims: {}, provider: nil)
      EnterpriseAccess.authorize!(user: user.reload, claims: claims, client: client)
      MutationAuthority.call(actor: user, organization: organization, platform_admin: false, claims: claims, provider: provider) { |_actor| nil }
      begin
        raise ArgumentError, "Choose SSO or Directory Sync setup" unless INTENTS.include?(intent)
        allowed = ENV.fetch("WORKOS_ADMIN_PORTAL_RETURN_URLS", "").split(",").map(&:strip).reject(&:empty?)
        uri = URI.parse(return_url.to_s)
        valid = allowed.include?(return_url) && uri.host.present? && uri.userinfo.nil? && uri.fragment.nil? && [ nil, "enterprise=1", "section=Home" ].include?(uri.query) &&
          (uri.scheme == "https" || (!Rails.env.production? && uri.scheme == "http" && %w[localhost 127.0.0.1].include?(uri.host)))
        raise ArgumentError, "Admin Portal return URL is not allowed" unless valid
        issued_at = Time.current
        url = client.portal(organization_id: organization.workos_organization_id, intent: intent, return_url: return_url)
        raise Client::Unavailable, "Invalid WorkOS portal link" unless url.is_a?(String) && url.present?
        begin
          parsed = URI.parse(url)
        rescue URI::InvalidURIError
          raise Client::Unavailable, "Invalid WorkOS portal link"
        end
        hosts = %w[setup.workos.com]
        custom_host = ENV["WORKOS_ADMIN_PORTAL_HOSTNAME"].to_s
        hosts << custom_host if custom_host.match?(/\A[a-z0-9]+(?:[.-][a-z0-9]+)*\z/i)
        raise Client::Unavailable, "Invalid WorkOS portal link" unless parsed.scheme == "https" && parsed.port == 443 && parsed.userinfo.nil? && hosts.include?(parsed.host)
        EnterpriseAccess.authorize!(user: user.reload, claims: claims, client: client)
        MutationAuthority.call(actor: user, organization: organization, platform_admin: false, claims: claims, provider: provider) do |actor|
          organization.enterprise_audit_events.create!(actor_user: actor, action: "portal.issued", metadata: { intent: intent })
          { url: url, expires_at: (issued_at + 5.minutes).iso8601 }
        end
      end
    rescue URI::InvalidURIError
      raise ArgumentError, "Invalid Admin Portal URL"
    end
  end
end
