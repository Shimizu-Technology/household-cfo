require "test_helper"
require_relative "../support/workos_auth_test_support"
require_relative "../support/workos_browser_auth_test_support"

class WorkosBrowserLoginOperationsTest < ActiveSupport::TestCase
  include WorkosAuthTestSupport
  self.use_transactional_tests = false
  self.fixture_paths = []
  ORIGIN = "https://householdcfomethod.com"

  def with_operation
    @operation_ids, @session_ids = [], []
    with_workos do
      response = WorkosBrowserAuthTestSupport::Response.new(
        user: WorkosBrowserAuthTestSupport::Profile.new(id: "user_test", email: "workos@example.com", email_verified: true),
        access_token: workos_token, refresh_token: "private-refresh", authentication_method: "magic_auth")
      provider = WorkosBrowserAuthTestSupport::FakeProvider.new(response)
      sessions = WorkosBrowserAuth::Sessions.new(provider: provider)
      browser = SecureRandom.urlsafe_base64(32)
      with_workos_http do
        sessions.login(origin: ORIGIN, browser: browser, return_to: "/#Review", screen_hint: "sign-in", popup: true)
        state = provider.options.fetch(:state)
        @operation_ids << WorkosBrowserLoginOperation.find_by!(state_digest: WorkosBrowserAuth::Sessions.digest(state)).id
        attempt = sessions.consume_login(state: state, browser: browser)
        yield sessions, provider, browser, state, attempt
      end
    end
  ensure
    WorkosBrowserSession.where(id: @session_ids).delete_all
    WorkosBrowserLoginOperation.where(id: @operation_ids).find_each(&:destroy!)
  end

  test "cancel after nonce consumption prevents an in-flight exchange from creating a session" do
    with_operation do |sessions, provider, browser, state, attempt|
      old_response = provider.response.dup
      old_response.access_token = workos_token({ "sid" => "session_previous" })
      old, old_cookie = sessions.establish_session(response: old_response, origin: ORIGIN)
      @session_ids << old.id
      entered, release = Queue.new, Queue.new
      provider.define_singleton_method(:exchange) do |code:, verifier:|
        exchanges << [ code, verifier ]
        entered << true
        release.pop
        response
      end
      worker = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          sessions.finish_login(attempt: attempt, code: "one-use-code")
        rescue WorkosAuth::InvalidToken
          :invalid
        end
      end
      entered.pop
      assert_equal :cancelled, sessions.cancel_login(origin: ORIGIN, browser: browser, state: state, cookie: old_cookie)
      release << true
      assert_equal :invalid, worker.value
      assert_equal [ "session_test" ], provider.revocations
      assert_equal [ "one-use-code" ], provider.exchanges.map(&:first)
      assert WorkosBrowserSession.exists?(old.id)
      assert_equal [ old.id ], WorkosBrowserSession.pluck(:id)
      assert_equal :cancelled, sessions.login_status(origin: ORIGIN, browser: browser, state: state, cookie: old_cookie)
    ensure
      release << true if worker&.alive?
      worker&.join
    end
  end

  test "cancellation and completed session creation have one atomic winner" do
    with_operation do |sessions, provider, browser, state, attempt|
      ready, release, results = Queue.new, Queue.new, Queue.new
      worker = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          release.pop
          record, cookie = sessions.finish_login(attempt: attempt, code: "one-use-code")
          results << [ record.id, cookie ]
        rescue WorkosAuth::InvalidToken
          results << :invalid
        end
      end
      ready.pop
      release << true
      cancellation = sessions.cancel_login(origin: ORIGIN, browser: browser, state: state)
      worker.join
      outcome = results.pop
      if outcome == :invalid
        assert_equal :cancelled, cancellation
        assert_equal :cancelled, sessions.login_status(origin: ORIGIN, browser: browser, state: state)
        assert_equal [ "session_test" ], provider.revocations
        assert_nil attempt.workos_browser_login_operation.reload.completed_at
      else
        id, cookie = outcome
        @session_ids << id
        assert_equal :account_changed, cancellation
        assert_equal :complete, sessions.login_status(origin: ORIGIN, browser: browser, state: state, cookie: cookie)
        assert_equal :complete, sessions.cancel_login(origin: ORIGIN, browser: browser, state: state, cookie: cookie)
        assert_empty provider.revocations
        assert_nil attempt.workos_browser_login_operation.reload.cancelled_at
      end
      assert_equal [ "one-use-code" ], provider.exchanges.map(&:first)
    ensure
      release << true if worker&.alive?
      worker&.join
    end
  end

  test "cancellation before hosted continuation creates no child attempt" do
    with_operation do |sessions, provider, browser, state, attempt|
      assert_equal :cancelled, sessions.cancel_login(origin: ORIGIN, browser: browser, state: state)
      assert_raises(WorkosAuth::InvalidToken) { sessions.policy_continuation(attempt: attempt, browser: browser) }
      assert_empty provider.exchanges
      assert_equal 0, WorkosBrowserLoginAttempt.where(workos_browser_login_operation_id: attempt.workos_browser_login_operation_id).count
    end
  end

  test "a callback cancelled during provider exchange cannot replace an existing browser cookie" do
    with_operation do |sessions, provider, browser, state, attempt|
      old_response = provider.response.dup
      old_response.access_token = workos_token({ "sid" => "session_previous" })
      old, old_cookie = sessions.establish_session(response: old_response, origin: ORIGIN)
      @session_ids << old.id
      # with_operation already consumed the first nonce; issue a new attempt
      # in the same operation for this actual HTTP callback race.
      sessions.policy_continuation(attempt: attempt, browser: browser)
      child_state = provider.options.fetch(:state)
      callback_browser = ActionDispatch::Integration::Session.new(Rails.application)
      cancelling_browser = ActionDispatch::Integration::Session.new(Rails.application)
      [ callback_browser, cancelling_browser ].each do |client|
        client.cookies["cfo_workos_login"] = browser
        client.cookies["cfo_workos_session"] = old_cookie
      end
      entered, release = Queue.new, Queue.new
      provider.define_singleton_method(:exchange) do |code:, verifier:|
        exchanges << [ code, verifier ]
        entered << true
        release.pop
        response
      end
      stub_method(WorkosBrowserAuth::Provider, :new, provider) do
        worker = Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            callback_browser.get "/api/auth/callback", params: { state: child_state, code: "blocked-code" }
          end
        end
        entered.pop
        cancelling_browser.post "/api/auth/login/cancel", params: { state: state }, as: :json,
          headers: { "X-Frontend-Origin" => ORIGIN, "Origin" => ORIGIN, "Sec-Fetch-Site" => "same-origin" }
        assert_equal({ "status" => "cancelled" }, cancelling_browser.response.parsed_body)
        release << true
        worker.join
        assert_equal 303, callback_browser.response.status
        assert_equal "#{ORIGIN}/login/complete?auth_error=invalid", callback_browser.response.location
        refute_includes callback_browser.response.headers["Set-Cookie"].to_s, "cfo_workos_session="
        assert_equal old_cookie, callback_browser.cookies["cfo_workos_session"]
        assert_equal [ "session_test" ], provider.revocations
        assert WorkosBrowserSession.exists?(old.id)
      ensure
        release << true if worker&.alive?
        worker&.join
      end
    end
  end
end
