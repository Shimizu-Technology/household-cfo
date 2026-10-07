class WorkosIdentityResolver
  class Forbidden < StandardError; end
  class NotInvited < Forbidden; end

  def self.resolve!(claims:)
    subject = claims.fetch("sub")
    identity = AuthenticationIdentity.find_by(provider: "workos", issuer: WorkosAuth.issuer, subject: subject)
    return sign_in!(identity.user) if identity

    profile = WorkosAuth.fetch_user_profile(subject)
    unless profile[:email_verified] && profile[:email].present?
      raise Forbidden, "A verified WorkOS email is required to accept an invitation."
    end
    User.transaction do
      user = User.lock.find_by("LOWER(email) = ?", profile[:email].strip.downcase)
      raise NotInvited, "This Household CFO account has not been invited yet." unless user
      # Another request may have accepted the same invitation while the profile was fetched.
      identity = AuthenticationIdentity.find_by(provider: "workos", issuer: WorkosAuth.issuer, subject: subject)
      next sign_in!(identity.user) if identity
      raise Forbidden, "This Household CFO invitation has been revoked." if user.revoked?
      # A pending_* Clerk placeholder may remain after migration. Status is the authority.
      unless user.invitation_status == "pending"
        raise Forbidden, "This Household CFO account requires an explicit WorkOS identity mapping."
      end
      user.authentication_identities.create!(provider: "workos", issuer: WorkosAuth.issuer, subject: subject)
      user.update!(invitation_status: "accepted", accepted_at: user.accepted_at || Time.current,
        last_sign_in_at: Time.current, first_name: profile[:first_name].presence, last_name: profile[:last_name].presence)
      user
    end
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
    # A conflict must never resolve by email to a different accepted identity.
    identity = AuthenticationIdentity.find_by(provider: "workos", issuer: WorkosAuth.issuer, subject: subject)
    raise Forbidden, "This Household CFO account is already linked to a different sign-in." unless identity
    sign_in!(identity.user)
  end

  def self.sign_in!(user)
    user.with_lock do
      raise Forbidden, "This Household CFO invitation has been revoked." if user.revoked?
      user.update!(last_sign_in_at: Time.current, invitation_status: "accepted", accepted_at: user.accepted_at || Time.current)
      user
    end
  end
end
