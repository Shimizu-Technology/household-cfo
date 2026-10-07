module Enterprise
  class SetupPolicy
    def self.enabled?(production: Rails.env.production?)
      %w[1 true yes on].include?(ENV.fetch("WORKOS_ENTERPRISE_SETUP_ENABLED", production ? "false" : "true").downcase)
    end

    def self.authorize!
      return if enabled?
      raise EnterpriseAccess::Denied.new(
        "Company sign-in and directory connections need administrator approval for separate WorkOS charges. Normal AuthKit sign-in remains available.",
        code: "enterprise_setup_not_enabled")
    end
  end
end
