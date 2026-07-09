require "test_helper"
require "tempfile"

class HouseholdFinanceVoiceTranscriberTest < ActiveSupport::TestCase
  test "fails closed when transcription is not configured" do
    result = HouseholdFinance::VoiceTranscriber.new(file: uploaded_audio, api_key: nil).call

    assert_not result.success?
    assert_equal "Voice transcription is not configured.", result.error
  end

  test "posts binary audio to Groq transcription endpoint" do
    requests = []
    response = ok_response(text: "I spent twenty five at McDonald's today.")
    audio_bytes = real_audio_bytes

    with_net_http_start_stub(response, requests) do
      result = HouseholdFinance::VoiceTranscriber.new(file: uploaded_audio(contents: audio_bytes), api_key: "gsk_test", model: "whisper-test").call

      assert result.success?
      assert_equal "I spent twenty five at McDonald's today.", result.transcript
    end

    request = requests.sole
    assert_equal "Bearer gsk_test", request["Authorization"]
    assert_match(/multipart\/form-data/, request["Content-Type"])
    assert_equal Encoding::BINARY, request.body.encoding
    assert_includes request.body, "name=\"model\"".b
    assert_includes request.body, "whisper-test".b
    assert_includes request.body, "filename=\"mia-voice.webm\"".b
    assert_includes request.body, audio_bytes.b
  end

  test "returns a safe error when the provider response is blank" do
    response = ok_response(text: "")

    with_net_http_start_stub(response) do
      result = HouseholdFinance::VoiceTranscriber.new(file: uploaded_audio, api_key: "gsk_test").call

      assert_not result.success?
      assert_equal "Voice transcription was blank. Please try again.", result.error
    end
  end

  private

  UploadedAudio = Struct.new(:tempfile, :original_filename, :content_type, keyword_init: true)

  def uploaded_audio(contents: "fake audio bytes")
    tempfile = Tempfile.new([ "mia-voice", ".webm" ])
    tempfile.binmode
    tempfile.write(contents)
    tempfile.rewind
    UploadedAudio.new(tempfile: tempfile, original_filename: "mia-voice.webm", content_type: "audio/webm")
  end

  def real_audio_bytes
    [ 0x1A, 0x45, 0xDF, 0xA3, 0x80, 0xFF, 0x00, 0x61 ].pack("C*")
  end

  def ok_response(payload)
    Net::HTTPOK.new("1.1", "200", "OK").tap do |response|
      response.instance_variable_set(:@body, payload.to_json)
      response.instance_variable_set(:@read, true)
    end
  end

  def with_net_http_start_stub(response, requests = [])
    singleton = class << Net::HTTP; self; end
    original = singleton.instance_method(:start)
    singleton.define_method(:start) do |*_args, **_kwargs, &block|
      http = Object.new
      http.define_singleton_method(:request) do |request|
        requests << request
        response
      end
      block.call(http)
    end
    yield
  ensure
    singleton.send(:remove_method, :start) if singleton.method_defined?(:start)
    singleton.define_method(:start, original)
  end
end
