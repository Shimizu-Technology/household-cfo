require "test_helper"
require "timeout"

class ApiV1HouseholdMemoriesConcurrencyTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  setup do
    suffix = SecureRandom.hex(6)
    @owner = User.create!(
      clerk_id: "memory-race-#{suffix}",
      email: "memory-race-#{suffix}@example.com",
      role: "participant",
      invitation_status: "accepted"
    )
    @household = HouseholdFinance::WorkspaceResolver.new(@owner).household
  end

  teardown do
    @household&.destroy!
    @owner&.destroy!
  end

  test "simultaneous exact REST creates converge on one memory" do
    request = {
      memory: {
        category: "preference",
        display_value: "Keep replies concise.",
        sensitivity: "ordinary",
        confirmed: true,
        structured_value: { "format" => "concise" },
        request_key: "concurrent-memory-key"
      }
    }

    responses = concurrent_posts([ request, request ])
    assert_equal [ 200, 201 ], responses.pluck(0).sort, responses.inspect
    assert_equal 1, @household.household_memories.where(owner_user: @owner, request_key: "concurrent-memory-key").count
    assert_equal 1, responses.map { |_status, body| body.dig("memory", "id") }.uniq.length
  end

  test "simultaneous mismatched REST creates keep one memory and conflict the loser" do
    base = {
      category: "preference",
      sensitivity: "ordinary",
      confirmed: true,
      request_key: "concurrent-mismatch-key"
    }
    first = { memory: base.merge(display_value: "Use a concise format.") }
    second = { memory: base.merge(display_value: "Use a detailed format.") }

    responses = concurrent_posts([ first, second ])
    assert_equal [ 201, 409 ], responses.pluck(0).sort, responses.inspect
    memories = @household.household_memories.where(owner_user: @owner, request_key: "concurrent-mismatch-key")
    assert_equal 1, memories.count
    assert_includes [ "Use a concise format.", "Use a detailed format." ], memories.sole.display_value
    assert_includes responses.find { |status, _body| status == 409 }.last.fetch("errors"), "This memory request ID was already used for different content."
  end

  private

  def concurrent_posts(requests)
    Rails.application.routes.recognize_path("/api/v1/household_memories", method: :post)
    ready = Queue.new
    release = Queue.new
    results = Queue.new
    errors = Queue.new
    threads = requests.map do |request|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          release.pop
          session = ActionDispatch::Integration::Session.new(Rails.application)
          session.post(
            "/api/v1/household_memories",
            params: request,
            headers: { "Authorization" => "Bearer test_token_#{@owner.id}" },
            as: :json
          )
          results << [ session.response.status, session.response.parsed_body ]
        rescue StandardError => error
          errors << error
        end
      end
    end

    Timeout.timeout(5) { requests.length.times { ready.pop } }
    requests.length.times { release << true }
    threads.each { |thread| thread.join(5) }
    assert threads.none?(&:alive?), "concurrent memory requests did not finish"
    assert errors.empty?, errors.size.times.map { errors.pop.full_message }.join("\n")
    requests.length.times.map { results.pop }
  ensure
    requests&.length&.times { release << true } if defined?(release)
    threads&.each { |thread| thread.join(1) }
  end
end
