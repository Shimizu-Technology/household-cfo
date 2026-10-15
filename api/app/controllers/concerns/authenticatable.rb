module Authenticatable
  extend ActiveSupport::Concern

  private

  def authenticate_user!
    token = bearer_token
    if token.blank?
      render_unauthorized("Missing bearer token")
      return
    end

    return authenticate_test_token!(token) if test_auth_token?(token)

    AuthenticationProvider.mode
    authenticate_workos!(token)
  rescue AuthenticationProvider::ConfigurationError => error
    render_service_unavailable(error.message)
  end

  # Local previews may run without a configured identity provider; production never does.
  def authenticate_user_unless_local_preview!
    return if local_identity_mode?

    authenticate_user!
  end

  # No provider was selected or configured. An explicit AUTH_PROVIDER, including an
  # unknown one, always fails closed instead of opening previews or test identities.
  def local_identity_mode?
    !Rails.env.production? && ENV["AUTH_PROVIDER"].blank? && !WorkosAuth.configured?
  end

  def authenticate_workos!(token)
    @authentication_claims = WorkosAuth.verify(token)
    @auth_provider = "workos"
    @auth_subject = @authentication_claims.fetch("sub")
    @current_user = resolve_workos_identity!
    EnterpriseAccess.authorize!(user: @current_user, claims: @authentication_claims)
    Sentry.set_user(id: @current_user.id, role: @current_user.role) if defined?(Sentry)
  rescue WorkosAuth::Unavailable => e
    render_service_unavailable(e.message)
  rescue WorkosAuth::InvalidToken => e
    render_unauthorized(e.message)
  rescue WorkosIdentityResolver::Forbidden => e
    render_forbidden(e.message)
  rescue EnterpriseAccess::Denied => e
    @current_user = nil
    render json: { error: e.message, code: e.code }, status: :forbidden
  rescue Enterprise::Client::Unavailable
    @current_user = nil
    render_service_unavailable("Enterprise access verification is temporarily unavailable")
  end

  def resolve_workos_identity!
    WorkosIdentityResolver.resolve!(claims: @authentication_claims)
  rescue WorkosIdentityResolver::NotInvited
    # Only an absent local invitation can enter directory admission. Existing
    # email/identity conflicts and revocation never fall back to provisioning.
    Enterprise::Admission.resolve!(subject: @auth_subject, claims: @authentication_claims,
      profile: WorkosAuth.fetch_user_profile(@auth_subject))
  end

  def current_user
    @current_user
  end

  def require_admin!
    authenticate_user! unless @current_user
    return if performed?

    render_forbidden("Admin access required") unless @current_user&.admin?
  end

  def require_staff!
    authenticate_user! unless @current_user
    return if performed?

    render_forbidden("Staff access required") unless @current_user&.staff?
  end

  def bearer_token
    header = request.headers["Authorization"].to_s
    header[/\ABearer\s+(.+)\z/i, 1]
  end

  # Test-only identities keep request tests and local live-API QA independent of
  # any external identity provider. They are never accepted outside the test env or
  # once WorkOS is selected, so they cannot shadow real provider verification.
  def test_auth_token?(token)
    Rails.env.test? && local_identity_mode? && (token.start_with?("test_token_") || token.start_with?("test_token:"))
  end

  def authenticate_test_token!(token)
    raise "Test authentication is unavailable outside the test environment" unless Rails.env.test?

    claims = test_token_claims(token)
    user = claims && test_token_user(claims)
    unless user
      render_unauthorized("Invalid or expired authentication token") unless claims
      render_forbidden(@authorization_failure_message || "This Household CFO account has not been invited yet.") if claims
      return
    end
    if user.revoked?
      render_forbidden("This Household CFO invitation has been revoked.")
      return
    end

    user.update!(last_sign_in_at: Time.current, invitation_status: "accepted", accepted_at: user.accepted_at || Time.current)
    @auth_provider = "test"
    @auth_subject = claims.fetch("sub")
    @authentication_claims = claims
    @current_user = user
    EnterpriseAccess.authorize!(user: @current_user, claims: @authentication_claims)
  rescue EnterpriseAccess::Denied => e
    @current_user = nil
    render json: { error: e.message, code: e.code }, status: :forbidden
  end

  def test_token_claims(token)
    if token.start_with?("test_token:")
      _prefix, subject, email, first_name, last_name = token.split(":", 5)
      return { "sub" => subject.presence || "test_user", "email" => email.presence || "participant@example.com",
        "first_name" => first_name.presence, "last_name" => last_name.presence }
    end

    user = User.find_by(id: token.delete_prefix("test_token_"))
    user && { "sub" => user.clerk_id, "email" => user.email, "first_name" => user.first_name, "last_name" => user.last_name }
  end

  # Mirrors invitation acceptance: an existing legacy subject signs in; otherwise a
  # pending invitation with the same email is linked. Nothing else is provisioned.
  def test_token_user(claims)
    user = User.find_by(clerk_id: claims.fetch("sub"))
    return user if user

    invited = User.find_by("LOWER(email) = ?", claims.fetch("email").to_s.downcase)
    return nil unless invited
    return invited if invited.revoked?
    unless invited.invitation_pending?
      @authorization_failure_message = "This Household CFO account is already linked to a different sign-in."
      return nil
    end

    names = { first_name: claims["first_name"], last_name: claims["last_name"] }.compact
    invited.update!(names.merge(clerk_id: claims.fetch("sub")))
    invited
  end

  def render_unauthorized(message = "Unauthorized")
    render json: { error: message }, status: :unauthorized
  end

  def render_forbidden(message = "Forbidden")
    render json: { error: message }, status: :forbidden
  end

  def render_service_unavailable(message)
    render json: { error: message }, status: :service_unavailable
  end
end
