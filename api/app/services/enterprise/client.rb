require "net/http"
require "json"

module Enterprise
  class Client
    class Unavailable < StandardError; end
    class NotFound < Unavailable; end
    EVENTS = %w[organization_membership.created organization_membership.updated organization_membership.deleted
      dsync.activated dsync.deleted dsync.user.created dsync.user.updated dsync.user.deleted
      dsync.group.created dsync.group.updated dsync.group.deleted dsync.group.user_added dsync.group.user_removed
      connection.activated connection.deactivated connection.deleted organization.deleted].freeze

    def request(method, path, query: {}, body: nil)
      key = ENV["WORKOS_API_KEY"].to_s
      raise Unavailable, "WorkOS enterprise integration is not configured" if key.empty?
      uri = URI("https://api.workos.com#{path}")
      uri.query = URI.encode_www_form(query) if query.any?
      req = (method == :post ? Net::HTTP::Post : Net::HTTP::Get).new(uri)
      req["Authorization"] = "Bearer #{key}"
      req["Content-Type"] = "application/json"
      req.body = JSON.generate(body) if body
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 3, read_timeout: 5) { |http| http.request(req) }
      raise NotFound, "WorkOS record is unavailable" if response.code == "404"
      raise Unavailable, "WorkOS request failed (#{response.code})" unless response.is_a?(Net::HTTPSuccess)
      JSON.parse(response.body)
    rescue JSON::ParserError, IOError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Net::ProtocolError
      raise Unavailable, "WorkOS is temporarily unavailable"
    end

    def list(path, **query)
      rows = []
      after = nil
      loop do
        page = request(:get, path, query: query.merge(limit: 100).merge(after ? { after: after } : {}))
        data = page.fetch("data")
        raise Unavailable, "WorkOS list response is invalid" unless data.is_a?(Array)
        rows.concat(data)
        cursor = page.dig("list_metadata", "after")
        break if data.empty? || cursor.blank?
        raise Unavailable, "WorkOS pagination did not advance" if after == cursor
        after = cursor
      end
      rows
    end

    def memberships(organization_id:, user_id: nil)
      list("/user_management/organization_memberships", **{ organization_id: organization_id, user_id: user_id }.compact)
    end

    def profile(subject)
      request(:get, "/user_management/users/#{safe_id(subject)}")
    end

    def directory_users(directory_id:, email: nil)
      list("/directory_users", **{ directory: directory_id, email: email }.compact)
    end

    def directory_groups(directory_id:, user_id: nil)
      list("/directory_groups", **{ directory: directory_id, user: user_id }.compact)
    end

    def sessions(subject)
      list("/user_management/users/#{safe_id(subject)}/sessions")
    end

    def events(after: nil)
      request(:get, "/events", query: { events: EVENTS, limit: 100, order: "asc" }.merge(after ? { after: after } : {}))
    end

    def portal(organization_id:, intent:, return_url:)
      request(:post, "/portal/generate_link", body: { organization: organization_id, intent: intent, return_url: return_url }).fetch("link")
    end

    def safe_id(value)
      raise Unavailable, "Invalid WorkOS identifier" unless value.to_s.match?(/\A[A-Za-z0-9_]+\z/)
      value
    end
  end
end
