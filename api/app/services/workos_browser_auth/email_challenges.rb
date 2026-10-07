module WorkosBrowserAuth
  class EmailChallenges
    class Expired < StandardError; end
    class InvalidCode < StandardError; end
    class RateLimited < StandardError; end
    PURPOSE = "workos-email-challenge-v1"
    RESEND_WAIT = 60.seconds
    MAX_ATTEMPTS = 5

    def initialize(provider: Provider.new)
      @provider = provider
      @sessions = Sessions.new(provider: provider)
    end

    def start(origin:, browser:, email:, return_to:, invitation_token: nil, ip_address: nil, user_agent: nil)
      email = normalize_email!(email)
      origin = Origins.approved!(origin)
      raise WorkosAuth::InvalidToken, "Invalid sign-in request" unless browser.to_s.match?(Sessions::OPAQUE)
      # Reuse OAuth validation for invitation and destination, without storing a
      # provider credential or the emailed six-digit code in browser state.
      destination = Origins.return_to!(return_to, origin: origin)
      validate_invitation!(invitation_token)
      delivery_limit!(email)
      WorkosEmailChallenge.where("expires_at < ?", Time.current).delete_all
      WorkosEmailDeliveryLimit.where("updated_at < ?", 1.day.ago).delete_all
      invited = User.where("LOWER(email) = ?", email).where(invitation_status: %w[pending accepted]).exists?
      context = { "email" => email, "return_to" => destination, "invitation_token" => invitation_token,
        "deliver" => invited }
      opaque = SecureRandom.urlsafe_base64(32)
      record = WorkosEmailChallenge.create!(challenge_digest: Sessions.digest(opaque), browser_digest: Sessions.digest(browser),
        frontend_origin: origin, client_id: WorkosAuth.client_id, encrypted_context: Encryption.encrypt(context, purpose: PURPOSE),
        expires_at: Sessions::LOGIN_TTL.from_now, resend_at: RESEND_WAIT.from_now)
      send_code!(record, context, ip_address: ip_address, user_agent: user_agent)
      metadata(record, opaque, context)
    rescue Provider::PolicyRequired
      record&.destroy!
      redirect(context, origin, browser)
    rescue StandardError
      record&.destroy!
      raise
    end

    def verify(origin:, browser:, challenge_id:, code:, ip_address: nil, user_agent: nil)
      raise InvalidCode, "That code did not work. Check it and try again" unless code.is_a?(String) && code.match?(/\A[0-9]{6}\z/)
      error = nil
      result = with_challenge(origin, browser, challenge_id) do |record, context|
        if record.verification_attempts >= MAX_ATTEMPTS
          error = Expired.new("This sign-in expired. Start again")
          next
        end
        record.update!(verification_attempts: record.verification_attempts + 1)
        begin
          raise WorkosAuth::InvalidToken, "Invalid sign-in code" unless context.fetch("deliver")
          response = @provider.authenticate_magic_auth(email: context.fetch("email"), code: code,
            invitation_token: context["invitation_token"], radar_auth_attempt_id: context["radar_auth_attempt_id"],
            ip_address: ip_address, user_agent: user_agent)
          unless response.user&.email.is_a?(String) && response.user.email.strip.downcase == context.fetch("email") &&
              (context["user_id"].nil? || response.user.id == context["user_id"])
            raise WorkosAuth::InvalidToken, "Invalid sign-in response"
          end
          session, cookie = @sessions.establish_session(response: response, origin: origin, admit: true)
          record.destroy!
          { step: "complete", return_to: context.fetch("return_to"), session: session, cookie: cookie }
        rescue Provider::PolicyRequired
          record.destroy!
          redirect(context, origin, browser)
        rescue EnterpriseAccess::Denied => failure
          if failure.code == "enterprise_sso_required"
            record.destroy!
            redirect(context, origin, browser)
          else
            error = failure
            nil
          end
        rescue WorkosAuth::InvalidToken
          error = InvalidCode.new("That code did not work. Check it and try again")
          nil
        rescue WorkosAuth::Unavailable, Provider::RateLimited, WorkosIdentityResolver::Forbidden, Enterprise::Client::Unavailable => failure
          error = failure
          nil
        end
      end
      raise error if error
      result
    end

    def resend(origin:, browser:, challenge_id:, ip_address: nil, user_agent: nil)
      error = nil
      result = with_challenge(origin, browser, challenge_id) do |record, context|
        raise Expired, "This sign-in expired. Start again" if record.verification_attempts >= MAX_ATTEMPTS
        raise RateLimited, "Please wait before requesting another code" if record.resend_at > Time.current
        delivery_limit!(context.fetch("email"))
        # Persist the cooldown even if the remote delivery result is uncertain.
        record.update!(resend_at: RESEND_WAIT.from_now)
        begin
          send_code!(record, context, ip_address: ip_address, user_agent: user_agent)
          metadata(record, challenge_id, context)
        rescue Provider::PolicyRequired
          record.destroy!
          redirect(context, origin, browser)
        rescue WorkosAuth::Unavailable, Provider::RateLimited, WorkosAuth::InvalidToken, WorkosIdentityResolver::Forbidden => failure
          error = failure
          nil
        end
      end
      raise error if error
      result
    end

    def cancel(origin:, browser:, challenge_id:)
      with_challenge(origin, browser, challenge_id) { |record, _| record.destroy! }
      nil
    rescue Expired
      nil
    end

    private

    def normalize_email!(value)
      unless value.is_a?(String) && value.bytesize <= 254 && value.strip.match?(/\A[^\s@[:cntrl:]]+@[^\s@[:cntrl:]]+\.[^\s@[:cntrl:]]+\z/)
        raise WorkosAuth::InvalidToken, "Enter a valid email address"
      end
      value.strip.downcase
    end

    def validate_invitation!(token)
      return if token.nil?
      unless token.is_a?(String) && token.present? && token.bytesize <= 4096 && !token.match?(/[[:space:][:cntrl:]]/)
        raise WorkosAuth::InvalidToken, "Invalid invitation"
      end
    end

    def delivery_limit!(email)
      digest = Sessions.digest("#{WorkosAuth.client_id}\0#{email}")
      WorkosEmailDeliveryLimit.consume!(identity_digest: digest)
    end

    def with_challenge(origin, browser, opaque)
      unless opaque.to_s.match?(Sessions::OPAQUE) && browser.to_s.match?(Sessions::OPAQUE)
        raise Expired, "This sign-in expired. Start again"
      end
      record = WorkosEmailChallenge.find_by(challenge_digest: Sessions.digest(opaque))
      raise Expired, "This sign-in expired. Start again" unless record
      record.with_lock do
        unless record.frontend_origin == Origins.approved!(origin) && record.client_id == WorkosAuth.client_id &&
            record.expires_at > Time.current && ActiveSupport::SecurityUtils.secure_compare(record.browser_digest, Sessions.digest(browser))
          raise Expired, "This sign-in expired. Start again"
        end
        yield record, Encryption.decrypt(record.encrypted_context, purpose: PURPOSE)
      end
    rescue ActiveRecord::RecordNotFound
      raise Expired, "This sign-in expired. Start again"
    end

    def send_code!(record, context, ip_address:, user_agent:)
      unless context.fetch("deliver")
        record.update!(expires_at: Sessions::LOGIN_TTL.from_now)
        return
      end
      response = @provider.create_magic_auth(email: context.fetch("email"), invitation_token: context["invitation_token"],
        ip_address: ip_address, user_agent: user_agent)
      expiry = Time.iso8601(response.expires_at)
      unless response.email.is_a?(String) && response.email.strip.downcase == context.fetch("email") && expiry > Time.current &&
          (response.user_id.nil? || response.user_id.to_s.match?(/\Auser_[A-Za-z0-9]+\z/)) &&
          (context["user_id"].nil? || context["user_id"] == response.user_id) &&
          (response.radar_auth_attempt_id.nil? || response.radar_auth_attempt_id.to_s.match?(/\Aradar_auth_attempt_[A-Za-z0-9]+\z/))
        raise WorkosAuth::Unavailable, "Invalid sign-in delivery response"
      end
      # Provider code is intentionally never retained, serialized or logged.
      context = context.merge("user_id" => response.user_id, "radar_auth_attempt_id" => response.radar_auth_attempt_id)
      record.update!(encrypted_context: Encryption.encrypt(context, purpose: PURPOSE),
        expires_at: [ expiry, Sessions::LOGIN_TTL.from_now ].min)
    rescue ArgumentError, NoMethodError, TypeError
      raise WorkosAuth::Unavailable, "Invalid sign-in delivery response"
    end

    def metadata(record, opaque, context)
      { step: "code", challenge_id: opaque, email: context.fetch("email"), expires_at: record.expires_at.iso8601,
        resend_after: [ (record.resend_at - Time.current).ceil, 0 ].max }
    end

    def redirect(context, origin, browser)
      { step: "redirect", authorization_url: @sessions.login(origin: origin, browser: browser,
        return_to: context.fetch("return_to"), screen_hint: "sign-in", invitation_token: context["invitation_token"],
        login_hint: context.fetch("email")) }
    end
  end
end
