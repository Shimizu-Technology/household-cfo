# frozen_string_literal: true

require "net/http"

# Opens an HTTPS connection for a chat-path OpenRouter call. A connection that
# never opened sent nothing, so one retry is safe and keeps a brief network blip
# from turning Mia's answer into a canned fallback. Read timeouts are not
# retried: the request may already be running and billed.
module OpenRouterConnection
  OPEN_ATTEMPTS = 2

  module_function

  def start(uri, read_timeout:, open_timeout:, &block)
    attempts = 0
    begin
      attempts += 1
      Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https", read_timeout: read_timeout, open_timeout: open_timeout, &block)
    rescue Net::OpenTimeout
      retry if attempts < OPEN_ATTEMPTS
      raise
    end
  end
end
