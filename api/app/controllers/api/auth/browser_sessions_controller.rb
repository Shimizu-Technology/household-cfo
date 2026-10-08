module Api
  module Auth
    class BrowserSessionsController < ApplicationController
      include ActionController::Cookies
      before_action :private_response
      before_action :workos_enabled!
      before_action :verified_origin!, except: :callback
      rate_limit to: 60, within: 1.minute, only: :login, with: -> {
        response.headers["Retry-After"] = "60"
        render json: { error: "Please wait a moment before trying again", code: "auth_rate_limited" }, status: :too_many_requests
      }

      rescue_from WorkosAuth::InvalidToken, with: :invalid_authentication
      rescue_from WorkosAuth::Unavailable, with: :unavailable
      rescue_from WorkosBrowserAuth::Provider::PolicyRequired, with: :invalid_authentication
      rescue_from WorkosBrowserAuth::Provider::RateLimited, with: :rate_limited
      rescue_from WorkosBrowserAuth::EmailChallenges::RateLimited, with: :rate_limited
      rescue_from WorkosBrowserAuth::EmailChallenges::Expired do
        render json: { error: "This sign-in expired. Start again", code: "email_challenge_expired" }, status: :gone
      end
      rescue_from WorkosBrowserAuth::EmailChallenges::InvalidCode do
        render json: { error: "That code did not work. Check it and try again", code: "email_code_invalid" }, status: :unauthorized
      end
      rescue_from WorkosIdentityResolver::Forbidden, EnterpriseAccess::Denied do
        render json: { error: "This account does not have access. Check your invitation or contact your program team", code: "program_access_denied" }, status: :forbidden
      end
      rescue_from Enterprise::Client::Unavailable, with: :unavailable
      rate_limit to: 60, within: 1.minute, only: %i[email_start email_verify email_resend], name: "email-sign-in", with: :rate_limited

      def options
        render json: { google_enabled: ENV["WORKOS_GOOGLE_ENABLED"] == "true" }
      end

      def email_start
        render_email_result(email_challenges.start(origin: @origin, browser: login_browser, email: params[:email],
          return_to: params[:return_to], invitation_token: params[:invitation_token], **request_context))
      end

      def email_verify
        browser = cookies[browser_cookie_name]
        result = email_challenges.verify(origin: @origin, browser: browser,
          challenge_id: params[:challenge_id], code: params[:code], **request_context)
        set_cookie(browser_cookie_name, browser, expires: WorkosBrowserAuth::Sessions::LOGIN_TTL.from_now) if result[:step] == "redirect"
        render_email_result(result)
      end

      def email_resend
        browser = cookies[browser_cookie_name]
        result = email_challenges.resend(origin: @origin, browser: browser, challenge_id: params[:challenge_id], **request_context)
        set_cookie(browser_cookie_name, browser, expires: WorkosBrowserAuth::Sessions::LOGIN_TTL.from_now)
        render_email_result(result)
      end

      def email_cancel
        email_challenges.cancel(origin: @origin, browser: cookies[browser_cookie_name], challenge_id: params[:challenge_id])
        head :no_content
      end

      def login
        browser = login_browser
        url = sessions.login(origin: @origin, browser: browser, return_to: params[:return_to], screen_hint: params[:screen_hint],
          organization_id: params[:organization_id], invitation_token: params[:invitation_token], authentication_method: params[:authentication_method],
          popup: params.key?(:popup) ? params[:popup] : false)
        set_cookie(browser_cookie_name, browser, expires: WorkosBrowserAuth::Sessions::LOGIN_TTL.from_now)
        render json: { authorization_url: url }
      end

      def login_cancel
        status = sessions.cancel_login(origin: @origin, browser: cookies[browser_cookie_name], state: params[:state], cookie: cookies[session_cookie_name])
        render json: { status: status }
      end

      def login_status
        status = sessions.login_status(origin: @origin, browser: cookies[browser_cookie_name], state: params[:state], cookie: cookies[session_cookie_name])
        render json: { status: status }
      end

      def callback
        attempt = sessions.consume_login(state: params[:state], browser: cookies[browser_cookie_name])
        # This top-level callback has no custom Origin header. One-use state
        # instead binds the approved frontend and browser.
        if params[:error].present?
          sessions.abandon_login(attempt: attempt)
          return redirect_to callback_destination(attempt, error: "cancelled"), allow_other_host: true, status: :see_other
        end
        record, token = sessions.finish_login(attempt: attempt, code: params[:code])
        begin
          old = sessions.find_session(cookie: cookies[session_cookie_name], origin: attempt.frontend_origin)
          old&.destroy!
        rescue WorkosAuth::InvalidToken
          # A stale local cookie cannot block a newly authenticated account.
        end
        set_cookie(session_cookie_name, token, expires: record.expires_at)
        redirect_to callback_destination(attempt), allow_other_host: true, status: :see_other
      rescue WorkosBrowserAuth::Provider::PolicyRequired
        begin
          browser = cookies[browser_cookie_name]
          url = sessions.policy_continuation(attempt: attempt, browser: browser)
          set_cookie(browser_cookie_name, browser, expires: WorkosBrowserAuth::Sessions::LOGIN_TTL.from_now)
          redirect_to url, allow_other_host: true, status: :see_other
        rescue WorkosAuth::InvalidToken, WorkosAuth::Unavailable, WorkosBrowserAuth::Provider::PolicyRequired, WorkosBrowserAuth::Provider::RateLimited => error
          callback_failure(attempt, error)
        end
      rescue WorkosAuth::InvalidToken, WorkosAuth::Unavailable, WorkosBrowserAuth::Provider::RateLimited, WorkosIdentityResolver::Forbidden => error
        callback_failure(attempt, error)
      end

      def show
        record = sessions.find_session(cookie: cookies[session_cookie_name], origin: @origin)
        render json: record ? sessions.session(record) : { client_id: WorkosAuth.client_id, user: nil }
      rescue WorkosAuth::InvalidToken
        clear_session_cookie
        invalid_authentication
      end

      def logout
        record = sessions.find_session(cookie: cookies[session_cookie_name], origin: @origin)
        expected_organization_id = params.key?(:expected_organization_id) ? params[:expected_organization_id] : WorkosBrowserAuth::Sessions::MISSING_EXPECTATION
        destination = sessions.logout(record, origin: @origin, expected_subject: params[:expected_subject], expected_organization_id: expected_organization_id)
        clear_session_cookie
        render json: { redirect_url: destination }
      rescue WorkosBrowserAuth::Sessions::AccountChanged
        render json: { error: "The signed-in account changed. Refresh before signing out", code: "account_changed" }, status: :conflict
      rescue WorkosAuth::InvalidToken
        clear_session_cookie
        render json: { redirect_url: @origin }
      end

      private

      def callback_failure(attempt, error)
        if attempt
          sessions.abandon_login(attempt: attempt)
          reason = if error.is_a?(WorkosIdentityResolver::Forbidden)
            "denied"
          elsif error.is_a?(WorkosAuth::Unavailable)
            "retry"
          else
            "invalid"
          end
          redirect_to callback_destination(attempt, error: reason), allow_other_host: true, status: :see_other
        else
          redirect_to "#{fallback_frontend_origin}/login?auth_error=invalid", allow_other_host: true, status: :see_other
        end
      end

      def callback_destination(attempt, error: nil)
        return attempt.return_to if !attempt.popup && error.nil?
        path = attempt.popup ? "/login/complete" : "/login"
        "#{attempt.frontend_origin}#{path}#{error ? "?auth_error=#{error}" : ""}"
      end

      def email_challenges
        @email_challenges ||= WorkosBrowserAuth::EmailChallenges.new
      end

      def request_context
        { ip_address: request.remote_ip, user_agent: request.user_agent.to_s.first(1024) }
      end

      def login_browser
        browser = cookies[browser_cookie_name]
        browser = SecureRandom.urlsafe_base64(32) unless browser.to_s.match?(WorkosBrowserAuth::Sessions::OPAQUE)
        set_cookie(browser_cookie_name, browser, expires: WorkosBrowserAuth::Sessions::LOGIN_TTL.from_now)
        browser
      end

      def render_email_result(result)
        if result[:step] == "complete"
          old = sessions.find_session(cookie: cookies[session_cookie_name], origin: @origin)
          old&.destroy!
          set_cookie(session_cookie_name, result.fetch(:cookie), expires: result.fetch(:session).expires_at)
        end
        render json: result.except(:session, :cookie)
      rescue WorkosAuth::InvalidToken
        # Stale cookies must not block a fresh verified login.
        set_cookie(session_cookie_name, result.fetch(:cookie), expires: result.fetch(:session).expires_at)
        render json: result.except(:session, :cookie)
      end

      def rate_limited(error = nil)
        retry_after = error.respond_to?(:retry_after_sec) ? error.retry_after_sec : 60
        response.headers["Retry-After"] = retry_after.to_s
        render json: { error: "Please wait before trying again", code: "auth_rate_limited", retry_after_sec: retry_after }, status: :too_many_requests
      end

      def sessions
        @sessions ||= WorkosBrowserAuth::Sessions.new
      end

      def fallback_frontend_origin
        configured = ENV["FRONTEND_URL"].presence || WorkosBrowserAuth::Origins::DEFAULTS.first
        WorkosBrowserAuth::Origins.approved!(configured)
      rescue WorkosAuth::InvalidToken
        raise WorkosAuth::Unavailable, "Program sign-in recovery is not configured"
      end

      def private_response
        response.headers["Cache-Control"] = "no-store, private"
        response.headers["Pragma"] = "no-cache"
        response.headers["Referrer-Policy"] = "no-referrer"
        response.headers["X-Content-Type-Options"] = "nosniff"
      end

      def workos_enabled!
        raise WorkosAuth::Unavailable, "WorkOS sign-in is not enabled" unless AuthenticationProvider.workos_enabled?
      rescue AuthenticationProvider::ConfigurationError => error
        raise WorkosAuth::Unavailable, error.message
      end

      def verified_origin!
        @origin = WorkosBrowserAuth::Origins.approved!(request.headers["X-Frontend-Origin"])
        origin_header = request.headers["Origin"]
        raise WorkosAuth::InvalidToken, "Invalid program origin" if origin_header.present? && origin_header != @origin
        if !request.get? && (origin_header != @origin || request.media_type != "application/json")
          raise WorkosAuth::InvalidToken, "Invalid sign-in request"
        end
        fetch_site = request.headers["Sec-Fetch-Site"]
        raise WorkosAuth::InvalidToken, "Invalid sign-in request" if fetch_site.present? && fetch_site != "same-origin"
      end

      def set_cookie(name, value, expires:)
        cookies[name] = { value: value, expires: expires, httponly: true, secure: Rails.env.production?, same_site: :lax, path: "/" }
      end

      def clear_session_cookie
        cookies.delete(session_cookie_name, secure: Rails.env.production?, same_site: :lax, path: "/")
      end

      def session_cookie_name
        Rails.env.production? ? "__Host-cfo_workos_session" : "cfo_workos_session"
      end

      def browser_cookie_name
        Rails.env.production? ? "__Host-cfo_workos_login" : "cfo_workos_login"
      end

      def invalid_authentication
        render json: { error: "Sign in again to continue", code: "invalid_session" }, status: :unauthorized
      end

      def unavailable
        response.headers["Retry-After"] = "3"
        render json: { error: "Sign-in is temporarily unavailable. Please try again", code: "auth_unavailable" }, status: :service_unavailable
      end
    end
  end
end
