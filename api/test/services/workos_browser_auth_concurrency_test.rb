require "test_helper"
require_relative "../support/workos_auth_test_support"
require_relative "../support/workos_browser_auth_test_support"

class WorkosBrowserAuthConcurrencyTest < ActiveSupport::TestCase
  include WorkosAuthTestSupport
  self.use_transactional_tests = false
  self.fixture_paths = []

  test "parallel refreshes serialize persisted rotation and nonce consumption is one use" do
    with_workos do
      response = WorkosBrowserAuthTestSupport::Response.new(
        user: WorkosBrowserAuthTestSupport::Profile.new(id: "user_test", email: "workos@example.com", email_verified: true),
        access_token: workos_token, refresh_token: "private-refresh-old", authentication_method: "magic_auth")
      provider = WorkosBrowserAuthTestSupport::FakeProvider.new(response)
      sessions = WorkosBrowserAuth::Sessions.new(provider: provider)
      browser = SecureRandom.urlsafe_base64(32)
      with_workos_http do
        sessions.login(origin: "https://householdcfomethod.com", browser: browser, return_to: "/", screen_hint: "sign-in")
        state = provider.options.fetch(:state)
        @owned_operation_id = WorkosBrowserLoginOperation.find_by!(state_digest: WorkosBrowserAuth::Sessions.digest(state)).id
        results = parallel(4) do
          begin
            sessions.consume_login(state: state, browser: browser)
          rescue WorkosAuth::InvalidToken
            :invalid
          end
        end
        assert_equal 1, results.count { |item| item.is_a?(WorkosBrowserLoginAttempt) }
        assert_equal 3, results.count(:invalid)
        attempt = results.find { |item| item.is_a?(WorkosBrowserLoginAttempt) }
        record, = sessions.finish_login(attempt: attempt, code: "private-code")
        @owned_id = record.id
        data = WorkosBrowserAuth::Encryption.decrypt(record.encrypted_credentials).merge("expires_at" => 1.second.ago.iso8601)
        record.update!(encrypted_credentials: WorkosBrowserAuth::Encryption.encrypt(data))
        response.refresh_token = "private-refresh-new"
        result = parallel(4) { sessions.session(WorkosBrowserSession.find(record.id)) }
        assert_equal 4, result.length
        assert result.all? { |item| item.fetch(:user).fetch(:id) == "user_test" }
        assert_equal [ "private-refresh-old" ], provider.refreshes
        assert_equal "private-refresh-new", WorkosBrowserAuth::Encryption.decrypt(record.reload.encrypted_credentials)["refresh_token"]
      end
    end
  ensure
    WorkosBrowserSession.where(id: @owned_id).delete_all if @owned_id
    WorkosBrowserLoginOperation.find_by(id: @owned_operation_id)&.destroy! if @owned_operation_id
  end

  private

  def parallel(count, &block)
    ready = Queue.new
    start = Queue.new
    threads = count.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          block.call
        end
      end
    end
    count.times { ready.pop }
    count.times { start << true }
    threads.map(&:value)
  ensure
    threads&.each(&:join)
  end
end
