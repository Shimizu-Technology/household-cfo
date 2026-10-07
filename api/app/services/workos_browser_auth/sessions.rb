require "digest"
require "securerandom"

module WorkosBrowserAuth
  class Sessions
    class AccountChanged < StandardError; end
    MISSING_EXPECTATION = Object.new.freeze
    OPAQUE = /\A[A-Za-z0-9_-]{43}\z/
    LOGIN_TTL = 10.minutes
    SESSION_TTL = 7.days
    REFRESH_MARGIN = 30.seconds

    def self.digest(value)
      Digest::SHA256.hexdigest(value.to_s)
    end

    def initialize(provider: Provider.new)
      @provider = provider
    end

    def login(origin:, browser:, return_to:, screen_hint:, organization_id: nil, invitation_token: nil)
      origin = Origins.approved!(origin)
      raise WorkosAuth::InvalidToken, "Invalid sign-in option" unless screen_hint.in?(%w[sign-in sign-up])
      raise WorkosAuth::InvalidToken, "Invalid organization" unless organization_id.nil? || organization_id.to_s.match?(/\Aorg_[A-Za-z0-9]+\z/)
      raise WorkosAuth::InvalidToken, "Invalid invitation" unless invitation_token.nil? || (invitation_token.is_a?(String) && invitation_token.present? && invitation_token.bytesize <= 4096 && !invitation_token.match?(/[[:space:]\x00-\x1f\x7f]/))
      state = SecureRandom.urlsafe_base64(32)
      pkce = WorkOS::PKCE.generate_pair
      WorkosBrowserLoginAttempt.where("expires_at < ?", Time.current).delete_all
      WorkosBrowserSession.where("expires_at < ?", Time.current).delete_all
      attempt = WorkosBrowserLoginAttempt.create!(state_digest: self.class.digest(state), browser_digest: self.class.digest(browser),
        frontend_origin: origin, return_to: Origins.return_to!(return_to, origin: origin), client_id: WorkosAuth.client_id,
        encrypted_verifier: Encryption.encrypt(pkce.fetch(:code_verifier), purpose: Encryption::PKCE_PURPOSE), expires_at: LOGIN_TTL.from_now)
      @provider.authorization_url(provider: "authkit", redirect_uri: "#{origin}/api/auth/callback", state: state,
        screen_hint: screen_hint, organization_id: organization_id, invitation_token: invitation_token,
        code_challenge: pkce.fetch(:code_challenge), code_challenge_method: "S256")
    rescue StandardError
      attempt&.destroy!
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
      credentials = validate_response!(@provider.exchange(code: code, verifier: Encryption.decrypt(attempt.encrypted_verifier, purpose: Encryption::PKCE_PURPOSE)))
      token = SecureRandom.urlsafe_base64(32)
      record = WorkosBrowserSession.create!(cookie_digest: self.class.digest(token), frontend_origin: attempt.frontend_origin,
        client_id: WorkosAuth.client_id, subject: credentials.fetch("user").fetch("id"), provider_session_id: credentials.fetch("sid"),
        encrypted_credentials: Encryption.encrypt(credentials), expires_at: SESSION_TTL.from_now)
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
