require "workos"

module WorkosBrowserAuth
  class Provider
    def initialize
      raise WorkosAuth::Unavailable, "WorkOS authentication is not configured" unless WorkosAuth.configured?
      # No retry of rotating refresh credentials or single-use authorization codes.
      @client = WorkOS::Client.new(api_key: ENV.fetch("WORKOS_API_KEY"), client_id: WorkosAuth.client_id,
        base_url: WorkosAuth.api_origin, timeout: 5, max_retries: 0, jwt_issuer: WorkosAuth.issuer)
    end

    def authorization_url(**options)
      safe_url!(@client.user_management.get_authorization_url(**options), "/user_management/authorize")
    end

    def exchange(code:, verifier:)
      call { @client.user_management.authenticate_with_code(code: code, code_verifier: verifier) }
    end

    def refresh(refresh_token:)
      call { @client.user_management.authenticate_with_refresh_token(refresh_token: refresh_token) }
    end

    def revoke(session_id:)
      call { @client.user_management.revoke_session(session_id: session_id) }
    rescue WorkosAuth::InvalidToken
      # A session already revoked or removed is safely logged out.
      nil
    end

    def logout_url(session_id:, origin:)
      safe_url!(@client.user_management.get_logout_url(session_id: session_id, return_to: origin), "/user_management/sessions/logout")
    end

    def active_session!(subject:, session_id:)
      row = Enterprise::Client.new.sessions(subject).find { |item| item["id"] == session_id }
      raise WorkosAuth::InvalidToken, "Sign in again to continue" unless row && row["user_id"] == subject && row["status"] == "active" && row["impersonator"].blank?
      row
    rescue Enterprise::Client::NotFound
      raise WorkosAuth::InvalidToken, "Sign in again to continue"
    rescue Enterprise::Client::Unavailable
      raise WorkosAuth::Unavailable, "Sign-in is temporarily unavailable"
    end

    private

    def safe_url!(value, path)
      uri = URI.parse(value)
      raise WorkosAuth::Unavailable, "Invalid sign-in destination" unless Origins.origin_for(uri) == WorkosAuth.api_origin &&
        uri.scheme == "https" && uri.port == 443 && uri.userinfo.nil? && uri.fragment.nil? && uri.path == path
      value
    rescue URI::InvalidURIError
      raise WorkosAuth::Unavailable, "Invalid sign-in destination"
    end

    def call
      yield
    rescue WorkOS::Error => error
      # Provider errors may embed tokens or private profile data. Never expose/log them.
      if error.http_status.to_i.in?([ 400, 401, 404, 422 ]) && error.code.to_s.in?(%w[invalid_grant invalid_token session_not_found session_expired session_revoked authentication_error])
        raise WorkosAuth::InvalidToken, "Sign in again to continue"
      end
      raise WorkosAuth::Unavailable, "Sign-in is temporarily unavailable"
    rescue JSON::ParserError, TypeError, SocketError, SystemCallError, IOError, Timeout::Error, OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError
      raise WorkosAuth::Unavailable, "Sign-in is temporarily unavailable"
    ensure
      begin
        @client.shutdown
      rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
        # A closed provider socket must not override the sanitized result.
      end
    end
  end
end
