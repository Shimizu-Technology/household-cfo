# Be sure to restart your server when you modify this file.

default_frontend_origins = %w[
  http://localhost:5173
  http://127.0.0.1:5173
  http://localhost:4174
  http://127.0.0.1:4174
  https://householdcfomethod.com
  https://www.householdcfomethod.com
  https://household-cfo.netlify.app
].freeze

configured_frontend_origins = ENV.fetch(
  "FRONTEND_URLS",
  ENV.fetch("FRONTEND_URL", "")
).split(",").map(&:strip).reject(&:blank?)

frontend_origins = (default_frontend_origins + configured_frontend_origins).uniq

Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins(*frontend_origins)

    resource "*",
      headers: :any,
      methods: %i[get post put patch delete options head]
  end
end
