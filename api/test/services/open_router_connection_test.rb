require "test_helper"

class OpenRouterConnectionTest < ActiveSupport::TestCase
  URI_UNDER_TEST = URI("https://openrouter.ai/api/v1/chat/completions")

  test "retries once when the connection never opened" do
    attempts = with_start_stub(->(attempt) { raise Net::OpenTimeout if attempt == 1; :ok }) do
      assert_equal :ok, OpenRouterConnection.start(URI_UNDER_TEST, read_timeout: 1, open_timeout: 1) { :ok }
    end
    assert_equal 2, attempts
  end

  test "gives up after the second connection timeout" do
    attempts = with_start_stub(->(_attempt) { raise Net::OpenTimeout }) do
      assert_raises(Net::OpenTimeout) { OpenRouterConnection.start(URI_UNDER_TEST, read_timeout: 1, open_timeout: 1) { :ok } }
    end
    assert_equal 2, attempts
  end

  test "never retries a read timeout because the request may already be running" do
    attempts = with_start_stub(->(_attempt) { raise Net::ReadTimeout }) do
      assert_raises(Net::ReadTimeout) { OpenRouterConnection.start(URI_UNDER_TEST, read_timeout: 1, open_timeout: 1) { :ok } }
    end
    assert_equal 1, attempts
  end

  private

  def with_start_stub(behavior)
    attempts = 0
    singleton = Net::HTTP.singleton_class
    original = Net::HTTP.method(:start)
    singleton.define_method(:start) do |*_args, **_kwargs, &block|
      attempts += 1
      behavior.call(attempts)
      block.call(nil)
    end
    yield
    attempts
  ensure
    singleton.send(:remove_method, :start)
    singleton.define_method(:start, original)
  end
end
