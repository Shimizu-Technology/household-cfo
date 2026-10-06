require "digest"

module Enterprise
  class ProviderState
    TTL = 30.seconds
    LOCKS = Array.new(32) { Mutex.new }.freeze

    def self.verified(membership:, claims:, client:, cache: Rails.cache)
      organization = membership.enterprise_organization
      components = [ WorkosAuth.client_id, WorkosAuth.issuer, organization.workos_organization_id,
        claims["sub"], claims["sid"], organization.updated_at.to_f, membership.updated_at.to_f ]
      digest = Digest::SHA256.hexdigest(components.to_json)
      key = "enterprise/provider-state/#{digest}"
      proof = cache.read(key)
      return proof if proof && proof[:valid_until] > Time.current.to_f
      LOCKS[digest.to_i(16) % LOCKS.size].synchronize do
        proof = cache.read(key)
        return proof if proof && proof[:valid_until] > Time.current.to_f
        checked_at = Time.current
        provider = client.memberships(organization_id: organization.workos_organization_id, user_id: claims["sub"]).find do |row|
          row["user_id"] == claims["sub"] && row["organization_id"] == organization.workos_organization_id && row["status"] == "active"
        end
        raise EnterpriseAccess::Denied, "Your enterprise membership is inactive or revoked" unless provider
        session = client.sessions(claims["sub"]).find { |row| row["id"] == claims["sid"] }
        valid = session && session["status"] == "active" && session["user_id"] == claims["sub"] && session["organization_id"] == organization.workos_organization_id
        raise EnterpriseAccess::Denied, "Your enterprise session is no longer active" unless valid
        unless membership.it_admin?
          snapshot = Provisioner.directory_snapshot(organization, client.profile(claims["sub"]), client: client)
          organization.with_lock { Provisioner.apply_directory_snapshot!(organization, membership, snapshot, observed_at: checked_at) }
        end
        remaining = TTL - (Time.current - checked_at)
        raise Client::Unavailable, "Enterprise verification timed out" unless remaining.positive?
        proof = { auth_method: session["auth_method"], valid_until: (checked_at + TTL).to_f }
        cache.write(key, proof, expires_in: remaining)
        proof
      end
    end
  end
end
