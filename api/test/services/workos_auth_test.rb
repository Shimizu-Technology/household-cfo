require "test_helper"
require_relative "../support/workos_auth_test_support"

class WorkosAuthTest < ActiveSupport::TestCase
  include WorkosAuthTestSupport

  test "verifies signed tokens against application bound keys and configured issuer" do
    with_workos do
      with_workos_http do
        assert_equal "user_test", WorkosAuth.verify(workos_token).fetch("sub")
        assert_equal "https://api.workos.com/sso/jwks/client_cfo", @workos_requests.first.first
        assert_equal 5, @workos_requests.first.last.fetch(:timeout)
        assert_equal false, @workos_requests.first.last.fetch(:follow_redirects)
        WorkosAuth.verify(workos_token)
        assert_equal 1, @workos_requests.length
      end
    end
  end

  test "rejects expired missing client wrong issuer wrong client and missing session claims" do
    with_workos do
      with_workos_http do
        [ { "exp" => 1.minute.ago.to_i }, { "exp" => nil }, { "iss" => "https://wrong.example.com" },
          { "client_id" => "client_other" }, { "client_id" => nil }, { "sid" => nil }, { "sub" => "user/unsafe" } ].each do |claims|
          assert_raises(WorkosAuth::InvalidToken) { WorkosAuth.verify(workos_token(claims)) }
        end
      end
    end
  end

  test "rejects wrong algorithms without fetching keys" do
    with_workos do
      assert_raises(WorkosAuth::InvalidToken) { WorkosAuth.verify(workos_token(key: "secret", algorithm: "HS256")) }
      assert_empty @workos_requests
    end
  end

  test "bad signatures do not force a network refresh" do
    with_workos do
      with_workos_http do
        bad_key = OpenSSL::PKey::RSA.generate(2048)
        assert_raises(WorkosAuth::InvalidToken) { WorkosAuth.verify(workos_token(key: bad_key)) }
        assert_equal 1, @workos_requests.length
      end
    end
  end

  test "refreshes once for a rotated key and bounds unknown kid refreshes" do
    with_workos do
      rotated_key = OpenSSL::PKey::RSA.generate(2048)
      rotated_jwk = JWT::JWK.new(rotated_key, "rotated")
      calls = 0
      handler = lambda do |_url, **_options|
        calls += 1
        keys = calls == 1 ? [ @signing_jwk.export ] : [ rotated_jwk.export ]
        WorkosResponse.new(200, { "keys" => keys.map(&:deep_stringify_keys) })
      end
      stub_method(HTTParty, :get, handler) do
        WorkosAuth.verify(workos_token)
        assert_equal "user_test", WorkosAuth.verify(workos_token(key: rotated_key, kid: "rotated")).fetch("sub")
        3.times { assert_raises(WorkosAuth::InvalidToken) { WorkosAuth.verify(workos_token(kid: "unknown")) } }
        assert_equal 2, calls
      end
    end
  end

  test "missing configuration network timeout and malformed keys are dependency failures" do
    with_workos("WORKOS_API_KEY" => nil) { assert_raises(WorkosAuth::Unavailable) { WorkosAuth.verify("token") } }
    with_workos do
      [ Timeout::Error, EOFError, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError ].each do |error_class|
        stub_method(HTTParty, :get, ->(*_args, **_options) { raise error_class }) do
          assert_raises(WorkosAuth::Unavailable) { WorkosAuth.verify(workos_token) }
        end
      end
      stub_method(HTTParty, :get, WorkosResponse.new(200, { "keys" => [] })) do
        assert_raises(WorkosAuth::Unavailable) { WorkosAuth.verify(workos_token) }
      end
    end
  end

  test "server profile identity must match and email verification must be a boolean" do
    with_workos do
      with_workos_http(profile: workos_profile.merge("email_verified" => "true")) do
        refute WorkosAuth.fetch_user_profile("user_test")[:email_verified]
        assert_equal "Bearer test-secret", @workos_requests.first.last.fetch(:headers).fetch("Authorization")
      end
      with_workos_http(profile: workos_profile.merge("id" => "user_other")) do
        assert_raises(WorkosAuth::InvalidToken) { WorkosAuth.fetch_user_profile("user_test") }
      end
    end
  end

  test "rejects malicious profile subjects and configured host values" do
    with_workos do
      assert_raises(WorkosAuth::InvalidToken) { WorkosAuth.fetch_user_profile("../other") }
      ENV["WORKOS_API_HOSTNAME"] = "attacker.example/path"
      refute WorkosAuth.configured?
    end
  end
end
