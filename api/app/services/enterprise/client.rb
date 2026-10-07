require "net/http"
require "json"
require "set"

module Enterprise
  class Client
    class Unavailable < StandardError; end
    class NotFound < Unavailable; end
    class CursorRejected < Unavailable; end
    EVENTS = %w[organization_membership.created organization_membership.updated organization_membership.deleted
      dsync.activated dsync.deleted dsync.user.created dsync.user.updated dsync.user.deleted
      dsync.group.created dsync.group.updated dsync.group.deleted dsync.group.user_added dsync.group.user_removed
      connection.activated connection.deactivated connection.deleted organization.deleted].freeze

    def request(method, path, query: {}, body: nil)
      key = ENV["WORKOS_API_KEY"].to_s
      raise Unavailable, "WorkOS enterprise integration is not configured" if key.empty?
      uri = URI("#{WorkosAuth.api_origin}#{path}")
      uri.query = URI.encode_www_form(query) if query.any?
      req = (method == :post ? Net::HTTP::Post : Net::HTTP::Get).new(uri)
      req["Authorization"] = "Bearer #{key}"
      req["Content-Type"] = "application/json"
      req.body = JSON.generate(body) if body
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 3, read_timeout: 5) { |http| http.request(req) }
      if path == "/events" && query[:after].present? && %w[400 404 422].include?(response.code)
        # Some provider versions do not expose a stable invalid-cursor error code.
        # Recovery verifies full state and retries without `after`; other query
        # errors still fail closed on that request rather than advancing a cursor.
        raise CursorRejected, "WorkOS event cursor was rejected"
      end
      raise NotFound, "WorkOS record is unavailable" if response.code == "404"
      raise Unavailable, "WorkOS request failed (#{response.code})" unless response.is_a?(Net::HTTPSuccess)
      data = object!(JSON.parse(response.body))
      if path.start_with?("/organizations/")
        record!(data, required: %w[id])
        raise Unavailable, "WorkOS organization response is invalid" unless data["id"] == path.split("/").last
      end
      data
    rescue WorkosAuth::Unavailable, JSON::ParserError, URI::InvalidURIError, TypeError, IOError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Net::ProtocolError
      raise Unavailable, "WorkOS is temporarily unavailable"
    end

    def list(path, **query)
      rows = []
      after = nil
      seen_cursors = Set.new
      loop do
        page = page!(request(:get, path, query: query.merge(limit: 100).merge(after ? { after: after } : {})))
        data = page.fetch("data")
        rows.concat(data)
        cursor = page.fetch("list_metadata").fetch("after")
        break if data.empty? || cursor.nil?
        raise Unavailable, "WorkOS pagination did not advance" if seen_cursors.include?(cursor)
        seen_cursors.add(cursor)
        after = cursor
      end
      if path.in?(%w[/directories /connections])
        rows.each { |row| record!(row, required: %w[id organization_id state]) }
      end
      rows
    end

    def memberships(organization_id:, user_id: nil)
      list("/user_management/organization_memberships", **{ organization_id: organization_id, user_id: user_id, statuses: %w[active inactive pending] }.compact).each do |row|
        record!(row, required: %w[id organization_id user_id status updated_at], timestamps: %w[updated_at])
        raise Unavailable, "WorkOS membership response is invalid" unless row["status"].in?(%w[active inactive pending])
      end
    end

    def profile(subject)
      data = record!(request(:get, "/user_management/users/#{safe_id(subject)}"), required: %w[id email])
      raise Unavailable, "WorkOS profile response is invalid" unless data["email_verified"].in?([ true, false ]) && data["id"] == subject
      data
    end

    def directory_users(directory_id:, email: nil)
      list("/directory_users", **{ directory: directory_id, email: email }.compact).each do |row|
        record!(row, required: %w[id directory_id organization_id state updated_at], nullable: %w[email], timestamps: %w[updated_at])
      end
    end

    def directory_groups(directory_id:, user_id: nil)
      list("/directory_groups", **{ directory: directory_id, user: user_id }.compact).each do |row|
        record!(row, required: %w[id directory_id organization_id])
      end
    end

    def sessions(subject)
      list("/user_management/users/#{safe_id(subject)}/sessions").each do |row|
        record!(row, required: %w[id user_id status auth_method], nullable: %w[organization_id])
      end
    end

    def events(after: nil, range_start: nil)
      query = { events: EVENTS, limit: 100, order: "asc" }.merge(after ? { after: after } : {}).merge(range_start ? { range_start: range_start } : {})
      page = page!(request(:get, "/events", query: query))
      page.fetch("data").each do |row|
        record!(row, required: %w[id event created_at], timestamps: %w[created_at])
        object!(row["data"])
      end
      page
    end

    def portal(organization_id:, intent:, return_url:)
      data = record!(request(:post, "/portal/generate_link", body: { organization: organization_id, intent: intent, return_url: return_url }), required: %w[link])
      data.fetch("link")
    end

    def object!(value)
      raise Unavailable, "WorkOS response is invalid" unless value.is_a?(Hash) && value.any?
      value
    end

    def record!(value, required:, nullable: [], timestamps: [])
      object!(value)
      required.each do |key|
        item = value.fetch(key)
        raise Unavailable, "WorkOS response is invalid" unless item.is_a?(String) && item.present?
      end
      nullable.each do |key|
        item = value[key]
        raise Unavailable, "WorkOS response is invalid" unless item.nil? || item.is_a?(String)
      end
      timestamps.each { |key| Time.iso8601(value.fetch(key)) }
      value
    rescue KeyError, ArgumentError, TypeError
      raise Unavailable, "WorkOS response is invalid"
    end

    def page!(value)
      object!(value)
      data = value.fetch("data")
      raise Unavailable, "WorkOS list response is invalid" unless data.is_a?(Array) && data.all? { |row| row.is_a?(Hash) }
      metadata = object!(value.fetch("list_metadata"))
      cursor = metadata.fetch("after")
      raise Unavailable, "WorkOS list cursor is invalid" unless cursor.nil? || (cursor.is_a?(String) && cursor.present?)
      value
    rescue KeyError, TypeError
      raise Unavailable, "WorkOS list response is invalid"
    end

    def safe_id(value)
      raise Unavailable, "Invalid WorkOS identifier" unless value.to_s.match?(/\A[A-Za-z0-9_]+\z/)
      value
    end
  end
end
