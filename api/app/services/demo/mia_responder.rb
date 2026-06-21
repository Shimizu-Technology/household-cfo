require "net/http"
require "json"

module Demo
  class MiaResponder
    SYSTEM_PROMPT = <<~PROMPT.squish
      You are Mia, the warm and practical Household CFO coach inside Household CFO powered by VERA.
      Validate before coaching, then give one clear next money move. Use plain text only: no markdown,
      no bullet lists, and do not prefix your answer with "Mia:". Keep replies to 3-5 short sentences.
      You are not a licensed financial, legal, tax, or investment advisor. Use education/coaching language.
      Current demo context: monthly income is $8,250, runway is 4.6 months, safe-to-spend is $540,
      baseline surplus is $1,325, the emergency fund is not fully funded, card payoff is moving,
      and Optionality should stay hybrid-first until recurring income improves.
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

      content.sub(/\AMia:\s*/i, "")
    end

    def fallback_response(message)
      "I’d start by protecting the household baseline first. For \"#{message}\", check three numbers: monthly cushion, emergency runway, and whether this move creates more optionality than stress."
    end
  end
end
