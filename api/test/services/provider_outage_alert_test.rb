require "test_helper"

class ProviderOutageAlertTest < ActiveSupport::TestCase
  Response = Struct.new(:code, :body)

  setup do
    @cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @env = %w[OPS_ALERT_EMAILS RESEND_API_KEY RESEND_FROM_EMAIL MAILER_FROM_EMAIL].to_h { |key| [ key, ENV[key] ] }
    ENV["OPS_ALERT_EMAILS"] = "ops@example.invalid"
    ENV["RESEND_API_KEY"] = "re_test"
    ENV["RESEND_FROM_EMAIL"] = "alerts@example.invalid"
    @sent = []
    sent = @sent
    @original_send = Resend::Emails.method(:send)
    Resend::Emails.singleton_class.define_method(:send) { |params| sent << params; { "id" => "email_test" } }
  end

  teardown do
    Rails.cache = @cache
    @env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    original = @original_send
    Resend::Emails.singleton_class.define_method(:send) { |*args, **kwargs, &block| original.call(*args, **kwargs, &block) }
  end

  test "an out-of-credits response logs an error and emails ops once an hour" do
    out_of_credits = Response.new("402", { error: { message: "Insufficient credits. Add more." } }.to_json)
    logs = capture_logs { 3.times { ProviderOutageAlert.check(out_of_credits, service: "mia_chat") } }

    assert_equal 3, logs.scan("ai_provider_account_failure").length
    assert_equal 1, @sent.length
    assert_equal [ "ops@example.invalid" ], @sent.first[:to]
    assert_includes @sent.first[:subject], "out of credits"
    assert_includes @sent.first[:text], "openrouter.ai/settings/credits"
    assert_includes @sent.first[:text], "Insufficient credits"
  end

  test "a rejected key alerts separately from credits" do
    ProviderOutageAlert.check(Response.new("402", "{}"), service: "mia_chat")
    ProviderOutageAlert.check(Response.new("401", "{}"), service: "document_extraction")

    assert_equal 2, @sent.length
    assert_includes @sent.last[:subject], "rejected the API key"
  end

  test "normal responses and ordinary provider errors do not alert" do
    [ Response.new("200", "{}"), Response.new("429", "{}"), Response.new("500", "{}"), Object.new ].each do |response|
      ProviderOutageAlert.check(response, service: "mia_chat")
    end

    assert_empty @sent
  end

  test "without an ops address it still logs but sends no email" do
    ENV.delete("OPS_ALERT_EMAILS")
    logs = capture_logs { ProviderOutageAlert.check(Response.new("402", "{}"), service: "mia_chat") }

    assert_includes logs, "ai_provider_account_failure"
    assert_empty @sent
  end

  private

  def capture_logs
    io = StringIO.new
    logger = ActiveSupport::Logger.new(io)
    Rails.logger.broadcast_to(logger)
    yield
    io.string
  ensure
    Rails.logger.stop_broadcasting_to(logger)
  end
end
