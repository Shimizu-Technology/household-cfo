# Be sure to restart your server when you modify this file.

require "uri"

local_frontend_origins = %w[
  http://localhost:5173
  http://127.0.0.1:5173
  http://[::1]:5173
  http://localhost:4174
  http://127.0.0.1:4174
  http://[::1]:4174
].freeze

production_frontend_origins = %w[
  https://householdcfomethod.com
  https://www.householdcfomethod.com
  https://household-cfo.netlify.app
].freeze

configured_frontend_origins = ENV.fetch(
  "FRONTEND_URLS",
  ENV.fetch("FRONTEND_URL", "")
).split(",").map(&:strip).reject(&:blank?)

default_frontend_origins = production_frontend_origins.dup
# Do not allow localhost origins in production by default; a page on any user's
# machine can claim a localhost Origin while sending authenticated requests.
default_frontend_origins.concat(local_frontend_origins) unless Rails.env.production?

local_origin_hosts = %w[localhost 127.0.0.1 ::1].freeze
local_origin = lambda do |origin|
  uri = URI.parse(origin)
  local_origin_hosts.include?(uri.hostname)
rescue URI::InvalidURIError
  false
end

frontend_origins = (default_frontend_origins + configured_frontend_origins).uniq
frontend_origins = frontend_origins.reject { |origin| local_origin.call(origin) } if Rails.env.production?

Rails.application.config.middleware.insert_before 0, Rack::Cors do
  # The unauthenticated bootstrap must be readable even when a program domain
  # is unknown or disabled so the browser can render the neutral VERA boundary.
  # The controller binds the requested hostname to this exact Origin and never
  # exposes authenticated workspace data.
  allow do
    origins do |source, _environment|
      Branding::Hostname.from_origin(source).present?
    rescue URI::InvalidURIError
      false
    end

    resource "/api/public/brand",
      headers: :any,
      methods: %i[get options head]
  end

  allow do
    origins(*frontend_origins) do |source, _environment|
      hostname = Branding::Hostname.from_origin(source)
      hostname.present? && Branding::ActiveDomainRegistry.active?(hostname)
    rescue URI::InvalidURIError, ActiveRecord::ActiveRecordError
      false
    end

    resource "*",
      headers: :any,
      methods: %i[get post put patch delete options head]
  end
end
