module ClerkAuthenticatable
  extend ActiveSupport::Concern

  private

  def authenticate_user!
    token = bearer_token
    if token.blank?
      render_unauthorized("Missing bearer token")
      return
    end

    unless ClerkAuth.configured? || test_auth_token?(token)
      render_service_unavailable("Clerk authentication is not configured")
      return
    end

    decoded = ClerkAuth.verify(token)
    unless decoded
      render_unauthorized("Invalid or expired authentication token")
      return
    end

    @authorization_failure_message = nil
    @current_user = find_or_create_user_from_clerk(decoded)
    return if @current_user

    render_forbidden(@authorization_failure_message || "This account is not authorized for Household CFO")
  end

  def authenticate_user_optional
    token = bearer_token
    return if token.blank?
    return unless ClerkAuth.configured? || test_auth_token?(token)

    decoded = ClerkAuth.verify(token)
    return unless decoded

    @current_user = find_or_create_user_from_clerk(decoded)
  end

  def authenticate_user_if_clerk_configured!
    return unless ClerkAuth.configured?

    authenticate_user!
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

  def test_auth_token?(token)
    Rails.env.test? && (token.start_with?("test_token_") || token.start_with?("test_token:"))
  end

  def find_or_create_user_from_clerk(decoded)
    clerk_id = decoded["sub"]
    return nil if clerk_id.blank?

    email = email_from_claims(decoded)
    first_name = decoded["first_name"] || decoded.dig("user", "first_name")
    last_name = decoded["last_name"] || decoded.dig("user", "last_name")
    clerk_profile = nil

    user = User.find_by(clerk_id: clerk_id)
    return sync_existing_user(user, email:, first_name:, last_name:) if user

    if email.blank? || first_name.blank? || last_name.blank?
      clerk_profile = ClerkAuth.fetch_user_profile(clerk_id)
      email ||= clerk_profile&.dig(:email)
      first_name ||= clerk_profile&.dig(:first_name)
      last_name ||= clerk_profile&.dig(:last_name)
    end

    if email.present?
      invited_user = User.find_by("LOWER(email) = ?", email.downcase)
      return link_invited_user(invited_user, clerk_id:, first_name:, last_name:) if invited_user
      return create_bootstrap_admin(clerk_id:, email:, first_name:, last_name:) if bootstrap_admin_email?(email)
    end

    return create_first_user_admin(clerk_id:, email:, first_name:, last_name:) if first_user_bootstrap_allowed?

    @authorization_failure_message = "This Household CFO account has not been invited yet."
    nil
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
    existing_user = User.find_by(clerk_id: clerk_id) || User.find_by("LOWER(email) = ?", email.to_s.downcase)
    return existing_user if existing_user && user_uniqueness_conflict?(e)

    Rails.logger.warn("[ClerkAuth] Unable to sync local user for Clerk user #{clerk_id}: #{e.message}")
    nil
  end

  def sync_existing_user(user, email:, first_name:, last_name:)
    if user.revoked?
      @authorization_failure_message = "This Household CFO invitation has been revoked."
      return nil
    end

    updates = { last_sign_in_at: Time.current }
    updates[:email] = email if email.present? && email.downcase != user.email
    updates[:first_name] = first_name if first_name.present? && first_name != user.first_name
    updates[:last_name] = last_name if last_name.present? && last_name != user.last_name
    updates[:invitation_status] = "accepted" if user.invitation_status != "accepted"
    updates[:accepted_at] = Time.current if user.accepted_at.blank?
    user.update!(updates)
    user
  end

  def link_invited_user(user, clerk_id:, first_name:, last_name:)
    if user.revoked?
      @authorization_failure_message = "This Household CFO invitation has been revoked."
      return nil
    end

    unless user.invitation_pending? || user.clerk_id == clerk_id
      @authorization_failure_message = "This Household CFO account is already linked to a different sign-in."
      return nil
    end

    user.update!(
      clerk_id: clerk_id,
      first_name: first_name.presence || user.first_name,
      last_name: last_name.presence || user.last_name,
      invitation_status: "accepted",
      accepted_at: user.accepted_at || Time.current,
      last_sign_in_at: Time.current
    )
    user
  end

  def create_bootstrap_admin(clerk_id:, email:, first_name:, last_name:)
    User.create!(
      clerk_id: clerk_id,
      email: email,
      first_name: first_name,
      last_name: last_name,
      role: "admin",
      invitation_status: "accepted",
      accepted_at: Time.current,
      last_sign_in_at: Time.current
    )
  end

  def create_first_user_admin(clerk_id:, email:, first_name:, last_name:)
    return nil unless User.count.zero?

    User.create!(
      clerk_id: clerk_id,
      email: email.presence || "#{clerk_id}@clerk.local",
      first_name: first_name,
      last_name: last_name,
      role: "admin",
      invitation_status: "accepted",
      accepted_at: Time.current,
      last_sign_in_at: Time.current
    )
  end

  def first_user_bootstrap_allowed?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch("ALLOW_FIRST_USER_BOOTSTRAP", "false"))
  end

  def bootstrap_admin_email?(email)
    bootstrap_admin_emails.include?(email.to_s.downcase)
  end

  def bootstrap_admin_emails
    ENV.fetch("CLERK_BOOTSTRAP_ADMIN_EMAILS", "")
      .split(",")
      .map { |address| address.strip.downcase }
      .reject(&:blank?)
  end

  def user_uniqueness_conflict?(error)
    return true if error.is_a?(ActiveRecord::RecordNotUnique)
    return false unless error.is_a?(ActiveRecord::RecordInvalid) && error.record.is_a?(User)

    error.record.errors.details.slice(:clerk_id, :email).values.flatten.any? { |detail| detail[:error] == :taken }
  end

  def email_from_claims(decoded)
    direct = decoded["email"] || decoded["email_address"] || decoded["primary_email_address"]
    return direct if direct.present?

    nested = decoded.dig("user", "email") || decoded.dig("user", "email_address") || decoded.dig("user", "primary_email_address")
    return nested if nested.present?

    emails = decoded["email_addresses"] || decoded.dig("user", "email_addresses")
    if emails.is_a?(Array)
      primary_id = decoded["primary_email_address_id"] || decoded.dig("user", "primary_email_address_id")
      primary = emails.find { |address| address.is_a?(Hash) && address["id"] == primary_id }
      first = primary || emails.find { |address| address.is_a?(Hash) }
      return first["email_address"] || first["email"] if first
    end

    nil
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
