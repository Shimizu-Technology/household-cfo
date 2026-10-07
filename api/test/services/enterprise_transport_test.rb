require "test_helper"
require_relative "../support/workos_auth_test_support"

class EnterpriseTransportTest < ActiveSupport::TestCase
  include WorkosAuthTestSupport

  test "configured API hostname routes management session directory events and portal requests" do
    with_workos("WORKOS_API_HOSTNAME" => "api.bank.example") do
      captured = []
      replies = {
        "/user_management/users/user_it" => { "id" => "user_it", "email" => "it@bank.test", "email_verified" => true },
        "/user_management/users/user_it/sessions" => page([ session ]),
        "/user_management/organization_memberships" => page([ membership ]),
        "/directory_users" => page([ directory_user ]),
        "/directory_groups" => page([ { "id" => "directory_group_bank", "directory_id" => "directory_bank", "organization_id" => "org_bank" } ]),
        "/events" => page([]),
        "/portal/generate_link" => { "link" => "https://setup.workos.com?token=test" }
      }
      with_transport(lambda { |request, host|
        captured << [ host, request.uri.path ]
        replies.fetch(request.uri.path).to_json
      }) do
        client = Enterprise::Client.new
        client.profile("user_it")
        client.sessions("user_it")
        client.memberships(organization_id: "org_bank", user_id: "user_it")
        client.directory_users(directory_id: "directory_bank")
        client.directory_groups(directory_id: "directory_bank", user_id: "directory_user_it")
        client.events
        client.portal(organization_id: "org_bank", intent: "sso", return_url: "https://app.bank.test")
      end
      assert_equal 7, captured.size
      assert captured.all? { |host, _path| host == "api.bank.example" }
    end
  end

  test "invalid server API hostname raises sanitized enterprise unavailable before network" do
    with_workos("WORKOS_API_HOSTNAME" => "api.bank.example:8443") do
      with_transport(->(*) { raise "Must not send API credentials" }) do
        error = assert_raises(Enterprise::Client::Unavailable) { Enterprise::Client.new.profile("user_it") }
        refute_includes error.message, "8443"
      end
    end
  end

  test "malformed JSON and nonobject responses become unavailable" do
    with_workos do
      [ nil, "not JSON", "null", "[]", '"string"', "{}" ].each do |body|
        with_transport(->(*) { body }) do
          assert_raises(Enterprise::Client::Unavailable) { Enterprise::Client.new.profile("user_it") }
        end
      end
    end
  end

  test "missing profile portal and resource keys become unavailable" do
    with_workos do
      [ [ { "id" => "user_it" }, :profile ], [ { "link" => nil }, :portal ], [ { "id" => "org_other" }, :organization ] ].each do |reply, kind|
        with_transport(->(*) { reply.to_json }) do
          assert_raises(Enterprise::Client::Unavailable) do
            client = Enterprise::Client.new
            case kind
            when :profile then client.profile("user_it")
            when :portal then client.portal(organization_id: "org_bank", intent: "sso", return_url: "https://app.bank.test")
            when :organization then client.request(:get, "/organizations/org_bank")
            end
          end
        end
      end
    end
  end

  test "malformed list records metadata and cursor become unavailable" do
    with_workos do
      [ { "unexpected" => [] }, { "data" => {} }, { "data" => [ nil ] },
       { "data" => [], "list_metadata" => [] }, { "data" => [], "list_metadata" => {} },
       { "data" => [], "list_metadata" => { "after" => 123 } }, page([ { "id" => "om_incomplete" } ]) ].each do |reply|
        with_transport(->(*) { reply.to_json }) do
          assert_raises(Enterprise::Client::Unavailable) { Enterprise::Client.new.memberships(organization_id: "org_bank") }
        end
      end
    end
  end

  test "invalid membership timestamp and event payload become unavailable" do
    with_workos do
      with_transport(->(*) { page([ membership.merge("updated_at" => "bad timestamp") ]).to_json }) do
        assert_raises(Enterprise::Client::Unavailable) { Enterprise::Client.new.memberships(organization_id: "org_bank") }
      end
      event = { "id" => "event_one", "event" => "organization_membership.updated", "created_at" => "2026-10-06T20:00:00Z", "data" => [] }
      with_transport(->(*) { page([ event ]).to_json }) do
        assert_raises(Enterprise::Client::Unavailable) { Enterprise::Client.new.events }
      end
    end
  end

  test "A B A pagination cycle fails after three requests" do
    with_workos do
      calls = 0
      with_transport(lambda { |_request, _host|
        cursor = [ "cursor_a", "cursor_b", "cursor_a" ].fetch(calls)
        calls += 1
        page([ membership ], after: cursor).to_json
      }) do
        assert_raises(Enterprise::Client::Unavailable) { Enterprise::Client.new.memberships(organization_id: "org_bank") }
      end
      assert_equal 3, calls
    end
  end

  test "pagination follows each unique cursor and preserves all rows" do
    with_workos do
      cursors = []
      with_transport(lambda { |request, _host|
        after = URI.decode_www_form(request.uri.query).to_h["after"]
        cursors << after
        if after.nil?
          page([ membership ], after: "cursor_next").to_json
        else
          page([ membership.merge("id" => "om_second") ]).to_json
        end
      }) do
        assert_equal [ "om_bank", "om_second" ], Enterprise::Client.new.memberships(organization_id: "org_bank").map { |row| row["id"] }
      end
      assert_equal [ nil, "cursor_next" ], cursors
    end
  end

  test "membership transport explicitly requests active pending and inactive states" do
    with_workos do
      captured = nil
      with_transport(lambda { |request, _host|
        captured = URI.decode_www_form(request.uri.query)
        rows = %w[active pending inactive].map { |status| membership.merge("id" => "om_#{status}", "status" => status) }
        page(rows).to_json
      }) do
        assert_equal %w[active pending inactive], Enterprise::Client.new.memberships(organization_id: "org_bank").map { |row| row["status"] }
      end
      assert_equal %w[active inactive pending], captured.select { |key, _value| key == "statuses" }.map(&:last)
    end
  end

  test "event cursor rejection is distinct from outages and invalid initial queries" do
    with_workos do
      [ 400, 404, 422 ].each do |status|
        response = Net::HTTPResponse.new("1.1", status.to_s, "Rejected")
        transport = Object.new
        transport.define_singleton_method(:request) { |_request| response }
        start = ->(*_args, **_options, &block) { block.call(transport) }
        stub_method(Net::HTTP, :start, start) do
          assert_raises(Enterprise::Client::CursorRejected) { Enterprise::Client.new.events(after: "event_old") }
          error = assert_raises(Enterprise::Client::Unavailable) { Enterprise::Client.new.events(range_start: Time.current.iso8601) }
          refute_kind_of Enterprise::Client::CursorRejected, error
        end
      end
      response = Net::HTTPResponse.new("1.1", "503", "Unavailable")
      transport = Object.new
      transport.define_singleton_method(:request) { |_request| response }
      stub_method(Net::HTTP, :start, ->(*_args, **_options, &block) { block.call(transport) }) do
        error = assert_raises(Enterprise::Client::Unavailable) { Enterprise::Client.new.events(after: "event_old") }
        refute_kind_of Enterprise::Client::CursorRejected, error
      end
    end
  end

  private

  def with_transport(handler)
    transport = Object.new
    current_host = nil
    transport.define_singleton_method(:request) do |request|
      body = handler.call(request, current_host)
      response = Net::HTTPOK.new("1.1", "200", "OK")
      response.define_singleton_method(:body) { body }
      response
    end
    start = lambda do |host, _port, **_options, &block|
      current_host = host
      block.call(transport)
    end
    stub_method(Net::HTTP, :start, start) { yield }
  end

  def page(data, after: nil)
    { "data" => data, "list_metadata" => { "after" => after } }
  end

  def membership
    { "id" => "om_bank", "user_id" => "user_it", "organization_id" => "org_bank", "status" => "active", "updated_at" => "2026-10-06T20:00:00Z" }
  end

  def session
    { "id" => "session_it", "user_id" => "user_it", "organization_id" => "org_bank", "auth_method" => "sso", "status" => "active" }
  end

  def directory_user
    { "id" => "directory_user_it", "directory_id" => "directory_bank", "organization_id" => "org_bank", "email" => "it@bank.test", "state" => "active", "updated_at" => "2026-10-06T20:00:00Z" }
  end
end
