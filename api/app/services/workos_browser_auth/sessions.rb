require "digest"
require "securerandom"

module WorkosBrowserAuth
  class Sessions
    class AccountChanged < StandardError; end
    MISSING_EXPECTATION = Object.new.freeze
    OPAQUE = /\A[A-Za-z0-9_-]{43}\z/
    LOGIN_TTL = 10.minutes
    LOGIN_CONTEXT_PURPOSE = "workos-browser-login-context-v1"
    SESSION_TTL = 7.days
    REFRESH_MARGIN = 30.seconds

    def self.digest(value)
      Digest::SHA256.hexdigest(value.to_s)
    end

    def initialize(provider: Provider.new)
      @provider = provider
    end

    def login(origin:, browser:, return_to:, screen_hint:, organization_id: nil, invitation_token: nil, authentication_method: nil, login_hint: nil, popup: false, operation: nil)
      origin = Origins.approved!(origin)
      raise WorkosAuth::InvalidToken, "Invalid sign-in request" unless browser.to_s.match?(OPAQUE)
      raise WorkosAuth::InvalidToken, "Invalid sign-in option" unless screen_hint.in?(%w[sign-in sign-up])
      raise WorkosAuth::InvalidToken, "Invalid sign-in option" unless popup == true || popup == false
      raise WorkosAuth::InvalidToken, "Invalid sign-in method" unless authentication_method.nil? || (authentication_method == "google" && ENV["WORKOS_GOOGLE_ENABLED"] == "true")
      raise WorkosAuth::InvalidToken, "Invalid sign-in method" if authentication_method == "google" && organization_id.present?
      raise WorkosAuth::InvalidToken, "Invalid organization" unless organization_id.nil? || organization_id.to_s.match?(/\Aorg_[A-Za-z0-9]+\z/)
      raise WorkosAuth::InvalidToken, "Invalid invitation" unless invitation_token.nil? || (invitation_token.is_a?(String) && invitation_token.present? && invitation_token.bytesize <= 4096 && !invitation_token.match?(/[[:space:]\x00-\x1f\x7f]/))
      state = SecureRandom.urlsafe_base64(32)
      pkce = WorkOS::PKCE.generate_pair
      WorkosBrowserLoginAttempt.where("expires_at < ?", Time.current).delete_all
      WorkosBrowserLoginOperation.where("expires_at < ?", Time.current).where.not(id: WorkosBrowserLoginAttempt.select(:workos_browser_login_operation_id).where.not(workos_browser_login_operation_id: nil)).delete_all
      WorkosBrowserSession.where("expires_at < ?", Time.current).delete_all
      owns_operation = operation.nil?
      operation ||= WorkosBrowserLoginOperation.create!(state_digest: self.class.digest(state), browser_digest: self.class.digest(browser),
        frontend_origin: origin, client_id: WorkosAuth.client_id, expires_at: LOGIN_TTL.from_now)
      attempt = nil
      operation.with_lock do
        usable_operation!(operation, origin: origin, browser: browser)
        attempt = WorkosBrowserLoginAttempt.create!(state_digest: self.class.digest(state), browser_digest: self.class.digest(browser),
          frontend_origin: origin, return_to: Origins.return_to!(return_to, origin: origin), client_id: WorkosAuth.client_id,
          encrypted_verifier: Encryption.encrypt(pkce.fetch(:code_verifier), purpose: Encryption::PKCE_PURPOSE), expires_at: operation.expires_at, popup: popup,
          workos_browser_login_operation: operation,
          encrypted_login_context: Encryption.encrypt({ "screen_hint" => screen_hint, "organization_id" => organization_id,
            "invitation_token" => invitation_token, "login_hint" => login_hint }, purpose: LOGIN_CONTEXT_PURPOSE))
      end
      @provider.authorization_url(provider: authentication_method == "google" ? "GoogleOAuth" : "authkit", redirect_uri: "#{origin}/api/auth/callback", state: state, login_hint: login_hint,
        # The direct Google route rejects AuthKit screen hints. Retain the hint
        # in encrypted login context for any later hosted policy handoff.
        screen_hint: authentication_method == "google" ? nil : screen_hint, organization_id: organization_id, invitation_token: invitation_token,
        code_challenge: pkce.fetch(:code_challenge), code_challenge_method: "S256")
    rescue StandardError => failure
      attempt&.destroy!
      operation&.destroy! if owns_operation
      raise WorkosAuth::InvalidToken, "This sign-in expired. Please start again" if failure.is_a?(ActiveRecord::RecordNotFound)
      raise
    end

    def consume_login(state:, browser:)
      raise WorkosAuth::InvalidToken, "This sign-in expired. Please start again" unless state.to_s.match?(OPAQUE) && browser.to_s.match?(OPAQUE)
      attempt = WorkosBrowserLoginAttempt.find_by(state_digest: self.class.digest(state))
      raise WorkosAuth::InvalidToken, "This sign-in expired. Please start again" unless attempt
      attempt.with_lock do
        raise WorkosAuth::InvalidToken, "This sign-in expired. Please start again" unless attempt.expires_at > Time.current &&
          attempt.client_id == WorkosAuth.client_id && ActiveSupport::SecurityUtils.secure_compare(attempt.browser_digest, self.class.digest(browser))
        Origins.approved!(attempt.frontend_origin)
        Origins.return_to!(attempt.return_to, origin: attempt.frontend_origin)
        attempt.destroy!
      end
      attempt
    rescue ActiveRecord::RecordNotFound
      raise WorkosAuth::InvalidToken, "This sign-in expired. Please start again"
    end

    def finish_login(attempt:, code:)
      raise WorkosAuth::InvalidToken, "Invalid sign-in code" unless code.is_a?(String) && code.present? && code.bytesize <= 2048
      operation = attempt_operation!(attempt)
      establish_session(response: @provider.exchange(code: code, verifier: Encryption.decrypt(attempt.encrypted_verifier, purpose: Encryption::PKCE_PURPOSE)),
        origin: attempt.frontend_origin, operation: operation)
    end

    def policy_continuation(attempt:, browser:)
      unless browser.to_s.match?(OPAQUE) && attempt.client_id == WorkosAuth.client_id && attempt.expires_at > Time.current &&
          ActiveSupport::SecurityUtils.secure_compare(attempt.browser_digest, self.class.digest(browser))
        raise WorkosAuth::InvalidToken, "This sign-in expired. Please start again"
      end
      context = attempt.encrypted_login_context.present? ? Encryption.decrypt(attempt.encrypted_login_context, purpose: LOGIN_CONTEXT_PURPOSE) : {}
      raise WorkosAuth::InvalidToken, "Invalid sign-in context" unless context.is_a?(Hash)
      # The original code and nonce were already consumed. Hosted AuthKit gets
      # a fresh browser-bound PKCE attempt to complete SSO, MFA or other policy.
      login(origin: attempt.frontend_origin, browser: browser, return_to: attempt.return_to, popup: attempt.popup,
        screen_hint: context.fetch("screen_hint", "sign-in"), organization_id: context["organization_id"],
        invitation_token: context["invitation_token"], login_hint: context["login_hint"], operation: attempt_operation!(attempt))
    end

    def cancel_login(origin:, browser:, state:, cookie: nil)
      operation = find_login_operation(origin: origin, browser: browser, state: state)
      return :cancelled unless operation
      operation.with_lock do
        return :cancelled if operation.expires_at <= Time.current
        return completed_operation_status(operation, cookie: cookie) if operation.completed_at
        operation.update!(cancelled_at: Time.current) unless operation.cancelled_at
        operation.login_attempts.delete_all
      end
      :cancelled
    rescue ActiveRecord::RecordNotFound
      :cancelled
    end

    def abandon_login(attempt:)
      operation = attempt_operation!(attempt)
      return unless operation
      operation.with_lock do
        unless operation.completed_at
          operation.update!(cancelled_at: Time.current) unless operation.cancelled_at
          operation.login_attempts.delete_all
        end
      end
    rescue ActiveRecord::RecordNotFound, WorkosAuth::InvalidToken
      nil
    end

    def login_status(origin:, browser:, state:, cookie: nil)
      operation = find_login_operation(origin: origin, browser: browser, state: state)
      return :cancelled unless operation && operation.expires_at > Time.current && operation.cancelled_at.nil?
      operation.completed_at ? completed_operation_status(operation, cookie: cookie) : :pending
    end

    def establish_session(response:, origin:, admit: false, operation: nil)
      credentials = validate_response!(response)
      if admit
        claims = WorkosAuth.verify(credentials.fetch("access_token"))
        begin
          begin
            user = WorkosIdentityResolver.resolve!(claims: claims)
          rescue WorkosIdentityResolver::NotInvited
            user = Enterprise::Admission.resolve!(subject: claims.fetch("sub"), claims: claims,
              profile: WorkosAuth.fetch_user_profile(claims.fetch("sub")))
          end
          EnterpriseAccess.authorize!(user: user, claims: claims)
        rescue WorkosIdentityResolver::Forbidden, EnterpriseAccess::Denied, Enterprise::Client::Unavailable
          # These freshly issued credentials were never made available to this
          # browser. Revoke that exact provider session, preserving any prior
          # local session and retaining the original authorization failure.
          begin
            @provider.revoke(session_id: credentials.fetch("sid"))
          rescue WorkosAuth::Unavailable, WorkosAuth::InvalidToken, Provider::RateLimited, Provider::PolicyRequired
            nil
          end
          raise
        end
      end
      token = SecureRandom.urlsafe_base64(32)
      record = nil
      if operation
        begin
          operation.with_lock do
            usable_operation!(operation, origin: origin)
            record = persist_session!(credentials: credentials, token: token, origin: origin)
            operation.update!(completed_at: Time.current, completed_cookie_digest: self.class.digest(token))
          end
        rescue WorkosAuth::InvalidToken, ActiveRecord::RecordNotFound
          revoke_unissued_credentials(credentials)
          raise WorkosAuth::InvalidToken, "This sign-in expired. Please start again"
        end
      else
        # Compatibility for attempts created before operation tracking and for
        # email challenges, which already serialize their own cancellation.
        record = persist_session!(credentials: credentials, token: token, origin: origin)
      end
      [ record, token ]
    end

    def find_session(cookie:, origin:)
      return nil if cookie.blank?
      raise WorkosAuth::InvalidToken, "Sign in again to continue" unless cookie.to_s.match?(OPAQUE)
      record = WorkosBrowserSession.find_by(cookie_digest: self.class.digest(cookie), frontend_origin: origin, client_id: WorkosAuth.client_id)
      raise WorkosAuth::InvalidToken, "Sign in again to continue" unless record
      record
    end

    def session(record)
      transient_error = nil
      result = record.with_lock do
        raise WorkosAuth::InvalidToken, "Sign in again to continue" unless record.expires_at > Time.current && record.client_id == WorkosAuth.client_id
        data = Encryption.decrypt(record.encrypted_credentials)
        @provider.active_session!(subject: record.subject, session_id: record.provider_session_id)
        profile = WorkosAuth.fetch_user_profile(record.subject)
        raise WorkosAuth::InvalidToken, "Verify your email to continue" unless profile[:email_verified]
        if data["pending_response"]
          data = validate_payload!(data.fetch("pending_response"))
          verify_record_identity!(record, data)
          record.update!(encrypted_credentials: Encryption.encrypt(data))
        end
        if Time.iso8601(data.fetch("expires_at")) <= REFRESH_MARGIN.from_now
          payload = response_payload(@provider.refresh(refresh_token: data.fetch("refresh_token")))
          begin
            data = validate_payload!(payload)
            verify_record_identity!(record, data)
            record.update!(encrypted_credentials: Encryption.encrypt(data))
          rescue WorkosAuth::Unavailable => error
            # Rotation succeeded but signing-key availability failed. Persist the
            # encrypted new credentials before leaving the transaction; retry
            # verifies this response instead of consuming the old refresh token.
            record.update!(encrypted_credentials: Encryption.encrypt({ "pending_response" => payload }))
            transient_error = error
            next nil
          end
        else
          claims = WorkosAuth.verify(data.fetch("access_token"))
          raise WorkosAuth::InvalidToken, "Sign in again to continue" unless claims["sub"] == record.subject && claims["sid"] == record.provider_session_id
        end
        { client_id: WorkosAuth.client_id, user: profile.slice(:id, :first_name, :last_name, :email),
          organization_id: data["organization_id"], authentication_method: data["authentication_method"],
          access_token: data.fetch("access_token"), expires_at: data.fetch("expires_at") }
      end
      raise transient_error if transient_error
      result
    rescue WorkosAuth::InvalidToken
      record.destroy! unless record.destroyed?
      raise
    rescue ActiveRecord::RecordNotFound, KeyError, ArgumentError, TypeError
      record.destroy! unless record.destroyed?
      raise WorkosAuth::InvalidToken, "Sign in again to continue"
    end

    def logout(record, origin:, expected_subject: nil, expected_organization_id: MISSING_EXPECTATION)
      return origin unless record
      record.with_lock do
        verify_logout_account!(record, expected_subject, expected_organization_id)
        # Stored signed-in metadata was checked before persistence; expiry of its
        # access token must not prevent revoking this one provider session.
        @provider.revoke(session_id: record.provider_session_id)
        destination = @provider.logout_url(session_id: record.provider_session_id, origin: origin)
        record.destroy!
        destination
      end
    rescue ActiveRecord::RecordNotFound
      origin
    end

    private

    def attempt_operation!(attempt)
      operation = attempt.workos_browser_login_operation
      if attempt.workos_browser_login_operation_id.present? && operation.nil?
        raise WorkosAuth::InvalidToken, "This sign-in expired. Please start again"
      end
      operation
    end

    def find_login_operation(origin:, browser:, state:)
      origin = Origins.approved!(origin)
      return nil unless state.to_s.match?(OPAQUE) && browser.to_s.match?(OPAQUE)
      operation = WorkosBrowserLoginOperation.find_by(state_digest: self.class.digest(state), frontend_origin: origin, client_id: WorkosAuth.client_id)
      operation if operation && ActiveSupport::SecurityUtils.secure_compare(operation.browser_digest, self.class.digest(browser))
    end

    def completed_operation_status(operation, cookie:)
      return :account_changed unless cookie.to_s.match?(OPAQUE) && operation.completed_cookie_digest &&
        ActiveSupport::SecurityUtils.secure_compare(operation.completed_cookie_digest, self.class.digest(cookie))
      active = WorkosBrowserSession.where(cookie_digest: operation.completed_cookie_digest, frontend_origin: operation.frontend_origin,
        client_id: operation.client_id).where("expires_at > ?", Time.current).exists?
      active ? :complete : :account_changed
    end

    def usable_operation!(operation, origin:, browser: nil)
      unless operation.frontend_origin == Origins.approved!(origin) && operation.client_id == WorkosAuth.client_id &&
          operation.expires_at > Time.current && operation.cancelled_at.nil? && operation.completed_at.nil? &&
          (browser.nil? || ActiveSupport::SecurityUtils.secure_compare(operation.browser_digest, self.class.digest(browser)))
        raise WorkosAuth::InvalidToken, "This sign-in expired. Please start again"
      end
    end

    def persist_session!(credentials:, token:, origin:)
      WorkosBrowserSession.create!(cookie_digest: self.class.digest(token), frontend_origin: Origins.approved!(origin),
        client_id: WorkosAuth.client_id, subject: credentials.fetch("user").fetch("id"), provider_session_id: credentials.fetch("sid"),
        encrypted_credentials: Encryption.encrypt(credentials), expires_at: SESSION_TTL.from_now)
    end

    def revoke_unissued_credentials(credentials)
      @provider.revoke(session_id: credentials.fetch("sid"))
    rescue WorkosAuth::Unavailable, WorkosAuth::InvalidToken, Provider::RateLimited, Provider::PolicyRequired
      nil
    end

    def verify_logout_account!(record, expected_subject, expected_organization_id)
      unless expected_subject.is_a?(String) && expected_subject == record.subject &&
          (expected_organization_id.nil? || (expected_organization_id.is_a?(String) && expected_organization_id.match?(/\Aorg_[A-Za-z0-9]+\z/)))
        raise AccountChanged, "The signed-in account changed. Refresh before signing out"
      end
      credentials = Encryption.decrypt(record.encrypted_credentials)
      data = credentials.fetch("pending_response", credentials)
      raise AccountChanged, "The signed-in account changed. Refresh before signing out" unless data.fetch("organization_id") == expected_organization_id
    rescue KeyError, TypeError, NoMethodError
      raise WorkosAuth::Unavailable, "Sign-in context is temporarily unavailable"
    end

    def verify_record_identity!(record, data)
      raise WorkosAuth::InvalidToken, "Sign in again to continue" unless data.fetch("user").fetch("id") == record.subject && data.fetch("sid") == record.provider_session_id
    end

    def validate_response!(response)
      validate_payload!(response_payload(response))
    end

    def response_payload(response)
      user = response.user
      raise WorkosAuth::Unavailable, "Invalid sign-in response" unless user
      { "access_token" => response.access_token, "refresh_token" => response.refresh_token,
        "user" => { "id" => user.id, "first_name" => user.first_name, "last_name" => user.last_name,
          "email" => user.email, "email_verified" => user.email_verified },
        "organization_id" => response.organization_id, "authentication_method" => response.authentication_method,
        "impersonated" => response.impersonator.present? }
    rescue NoMethodError
      raise WorkosAuth::Unavailable, "Invalid sign-in response"
    end

    def validate_payload!(payload)
      claims = WorkosAuth.verify(payload.fetch("access_token"))
      user = payload.fetch("user")
      unless user["id"] == claims["sub"] && user["email"].is_a?(String) && user["email"].present? &&
          user["email_verified"] == true && %w[first_name last_name].all? { |key| user[key].nil? || user[key].is_a?(String) } &&
          payload["refresh_token"].is_a?(String) && payload["refresh_token"].present? && payload["refresh_token"].bytesize <= 16_384 && !payload["impersonated"] &&
          (payload["organization_id"].nil? || payload["organization_id"].to_s.match?(/\Aorg_[A-Za-z0-9]+\z/)) && payload["organization_id"] == claims["org_id"] &&
          (payload["authentication_method"].nil? || payload["authentication_method"].is_a?(String))
        raise WorkosAuth::InvalidToken, "Invalid sign-in response"
      end
      payload.except("impersonated").merge("sid" => claims.fetch("sid"), "expires_at" => Time.at(claims.fetch("exp")).utc.iso8601)
    end
  end
end
