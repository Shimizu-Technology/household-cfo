class WorkosIdentityMapping
  class Conflict < StandardError; end

  # Operator-only explicit mapping. Does not change roles, invitations, Clerk IDs or finance ownership.
  def self.bind!(user_id:, subject:, expected_clerk_id:, dry_run: true)
    profile = WorkosAuth.fetch_user_profile(subject)
    User.transaction do
      user = User.lock.find(user_id)
      raise Conflict, "Local Clerk identity changed; re-check the mapping" unless user.clerk_id == expected_clerk_id
      raise Conflict, "Cannot map a revoked account" if user.revoked?
      unless profile[:email_verified] && profile[:email].to_s.strip.downcase == user.email
        raise Conflict, "WorkOS verified email must match the selected local account"
      end
      scope = AuthenticationIdentity.where(provider: "workos", issuer: WorkosAuth.issuer)
      existing = scope.find_by(subject: subject)
      raise Conflict, "WorkOS identity belongs to a different local user" if existing && existing.user_id != user.id
      previous = scope.find_by(user_id: user.id)
      raise Conflict, "Local account already has a different WorkOS identity" if previous && previous.subject != subject
      return existing if dry_run || existing
      scope.create!(user: user, subject: subject)
    end
  end
end
