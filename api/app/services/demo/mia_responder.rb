require "net/http"
require "json"

module Demo
  class MiaResponder
    SYSTEM_PROMPT = <<~PROMPT.squish
      You are Mia, the warm and practical Household CFO guide inside Household CFO powered by VERA.
      Give concise, emotionally intelligent financial coaching using demo-safe language.
      Do not claim to be a licensed financial advisor. Focus on stability, optionality, and next actions.
    PROMPT

    def initialize(api_key: ENV["OPENROUTER_API_KEY"], model: ENV.fetch("OPENROUTER_MODEL", "google/gemini-2.5-flash"))
      @api_key = api_key
      @model = model
    end

    def call(message)
      clean_message = message.to_s.strip
      return fallback_response("What are we trying to decide?") if clean_message.empty?
      return fallback_response(clean_message) if @api_key.to_s.strip.empty?

      openrouter_response(clean_message)
    rescue StandardError
      fallback_response(clean_message)
    end

    private

    def openrouter_response(message)
      uri = URI("https://openrouter.ai/api/v1/chat/completions")
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{@api_key}"
      request["Content-Type"] = "application/json"
      request["HTTP-Referer"] = "https://github.com/Shimizu-Technology/household-cfo"
      request["X-Title"] = "Household CFO powered by VERA"
      request.body = {
        model: @model,
        messages: [
          { role: "system", content: SYSTEM_PROMPT },
          { role: "user", content: message }
        ],
        max_tokens: 220,
        temperature: 0.5
      }.to_json

      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, read_timeout: 20, open_timeout: 5) do |http|
        http.request(request)
      end

      return fallback_response(message) unless response.is_a?(Net::HTTPSuccess)

      parsed = JSON.parse(response.body)
      content = parsed.dig("choices", 0, "message", "content").presence
      return fallback_response(message) unless content

      content.start_with?("Mia") ? content : "Mia: #{content}"
    end

    def fallback_response(message)
      "Mia: I’d start by protecting the household baseline first. For \"#{message}\", check three numbers: monthly cushion, emergency runway, and whether this move creates more optionality than stress."
    end
  end
end
