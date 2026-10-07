module WorkosBrowserAuthTestSupport
  Response = Struct.new(:user, :access_token, :refresh_token, :organization_id, :authentication_method, :impersonator, keyword_init: true)
  Profile = Struct.new(:id, :email, :email_verified, :first_name, :last_name, keyword_init: true)

  class FakeProvider
    attr_accessor :response, :failure, :active_failure, :refreshes, :exchanges, :revocations, :options
    def initialize(response)
      @response, @refreshes, @exchanges, @revocations = response, [], [], []
    end
    def authorization_url(**options)
      @options = options
      "https://api.workos.com/user_management/authorize?#{URI.encode_www_form(options)}"
    end
    def exchange(code:, verifier:)
      @exchanges << [ code, verifier ]
      raise failure if failure
      response
    end
    def refresh(refresh_token:)
      @refreshes << refresh_token
      raise failure if failure
      response
    end
    def active_session!(**)
      raise active_failure if active_failure
    end
    def revoke(session_id:)
      raise failure if failure
      @revocations << session_id
    end
    def logout_url(session_id:, origin:)
      "https://api.workos.com/user_management/sessions/logout?#{URI.encode_www_form(session_id: session_id, return_to: origin)}"
    end
  end
end
