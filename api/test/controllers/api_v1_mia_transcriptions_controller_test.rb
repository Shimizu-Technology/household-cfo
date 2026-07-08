require "test_helper"
require "tempfile"

class ApiV1MiaTranscriptionsControllerTest < ActionDispatch::IntegrationTest
  test "create requires audio upload" do
    user = create_user

    post "/api/v1/mia/transcriptions", headers: auth_headers(user)

    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body).fetch("errors").join, "No audio uploaded"
  end

  test "create rejects unsupported audio uploads" do
    user = create_user

    post "/api/v1/mia/transcriptions",
      params: { audio: uploaded_file(extension: ".txt", content_type: "text/plain") },
      headers: auth_headers(user)

    assert_response :unprocessable_entity
    assert_match(/Unsupported audio type/, JSON.parse(response.body).fetch("errors").join)
  end

  test "create returns service unavailable when transcription is not configured" do
    user = create_user

    post "/api/v1/mia/transcriptions",
      params: { audio: uploaded_file },
      headers: auth_headers(user)

    assert_response :service_unavailable
    assert_includes JSON.parse(response.body).fetch("errors").join, "not configured"
  end

  test "create returns transcript from backend transcriber" do
    user = create_user
    fake_transcriber = ->(file:) {
      assert_equal "mia-voice.webm", file.original_filename
      result = Object.new.tap do |object|
        object.define_singleton_method(:success?) { true }
        object.define_singleton_method(:transcript) { "I spent twenty five at McDonald's today." }
      end
      Object.new.tap { |object| object.define_singleton_method(:call) { result } }
    }

    with_singleton_stub(HouseholdFinance::VoiceTranscriber, :new, fake_transcriber) do
      post "/api/v1/mia/transcriptions",
        params: { audio: uploaded_file },
        headers: auth_headers(user)
    end

    assert_response :success
    assert_equal "I spent twenty five at McDonald's today.", JSON.parse(response.body).fetch("transcript")
  end

  private

  def create_user(email: "voice-user@example.com")
    User.create!(
      clerk_id: "clerk_#{SecureRandom.hex(6)}",
      email: email,
      first_name: "Voice",
      last_name: "User",
      role: "participant",
      invitation_status: "accepted"
    )
  end

  def uploaded_file(extension: ".webm", content_type: "audio/webm", contents: "fake audio bytes")
    tempfile = Tempfile.new([ "mia-voice", extension ])
    tempfile.binmode
    tempfile.write(contents)
    tempfile.rewind
    Rack::Test::UploadedFile.new(tempfile.path, content_type, true, original_filename: "mia-voice#{extension}")
  end

  def auth_headers(user)
    { "Authorization" => "Bearer test_token_#{user.id}" }
  end

  def with_singleton_stub(target, method_name, replacement)
    singleton = class << target; self; end
    original = singleton.instance_method(method_name)
    singleton.define_method(method_name) do |*args, **kwargs, &block|
      replacement.call(*args, **kwargs, &block)
    end
    yield
  ensure
    singleton.send(:remove_method, method_name) if singleton.method_defined?(method_name)
    singleton.define_method(method_name, original)
  end
end
