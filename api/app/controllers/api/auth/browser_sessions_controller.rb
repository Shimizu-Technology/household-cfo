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

      def login
        browser = cookies[browser_cookie_name]
        browser = SecureRandom.urlsafe_base64(32) unless browser.to_s.match?(WorkosBrowserAuth::Sessions::OPAQUE)
        url = sessions.login(origin: @origin, browser: browser, return_to: params[:return_to], screen_hint: params[:screen_hint],
          organization_id: params[:organization_id], invitation_token: params[:invitation_token])
        set_cookie(browser_cookie_name, browser, expires: WorkosBrowserAuth::Sessions::LOGIN_TTL.from_now)
        render json: { authorization_url: url }
      end

      def callback
        attempt = sessions.consume_login(state: params[:state], browser: cookies[browser_cookie_name])
        # This top-level callback has no custom Origin header. One-use state
        # instead binds the approved frontend and browser.
        if params[:error].present?
          return redirect_to "#{attempt.frontend_origin}/login?auth_error=cancelled", allow_other_host: true, status: :see_other
        end
        record, token = sessions.finish_login(attempt: attempt, code: params[:code])
        begin
          old = sessions.find_session(cookie: cookies[session_cookie_name], origin: attempt.frontend_origin)
          old&.destroy!
        rescue WorkosAuth::InvalidToken
          # A stale local cookie cannot block a newly authenticated account.
        end
        set_cookie(session_cookie_name, token, expires: record.expires_at)
        redirect_to attempt.return_to, allow_other_host: true, status: :see_other
      rescue WorkosAuth::InvalidToken, WorkosAuth::Unavailable => error
        if attempt
          reason = error.is_a?(WorkosAuth::Unavailable) ? "retry" : "invalid"
          redirect_to "#{attempt.frontend_origin}/login?auth_error=#{reason}", allow_other_host: true, status: :see_other
        else
          redirect_to "#{fallback_frontend_origin}/login?auth_error=invalid", allow_other_host: true, status: :see_other
        end
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
        destination = sessions.logout(record, origin: @origin)
        clear_session_cookie
        render json: { redirect_url: destination }
      rescue WorkosAuth::InvalidToken
        clear_session_cookie
        render json: { redirect_url: @origin }
      end

      private

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
        raise WorkosAuth::Unavailable, "WorkOS sign-in is not enabled" unless ENV["AUTH_PROVIDER"] == "workos" && WorkosAuth.configured?
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
