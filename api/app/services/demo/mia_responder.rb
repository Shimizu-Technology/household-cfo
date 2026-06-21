require "net/http"
require "json"

module Demo
  class MiaResponder
    LOW_SIGNAL_EXACT_MESSAGES = [ "test", "testing", "hi", "hello", "hey" ].freeze
    TEST_MESSAGES = [ "test", "testing" ].freeze

    SYSTEM_PROMPT = <<~PROMPT.squish
      You are Mia, the warm and practical Household CFO coach inside Household CFO powered by VERA.
      Do not over-praise inputs. If a user sends a test, greeting, fragment, or unclear phrase, briefly acknowledge and ask what money decision they want help with.
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

    def call(message, history: [])
      clean_message = message.to_s.strip
      return fallback_response("What are we trying to decide?") if clean_message.empty?
      return low_signal_response(clean_message) if low_signal_message?(clean_message)
      return fallback_response(clean_message) if @api_key.to_s.strip.empty?

      openrouter_response(clean_message, history)
    rescue StandardError
      fallback_response(clean_message)
    end

    private

    def openrouter_response(message, history)
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
          *conversation_history(history),
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

    def conversation_history(history)
      Array(history).filter_map do |message|
        role = message[:role] || message["role"]
        content = message[:content] || message["content"]
        next unless role.to_s.in?([ "assistant", "user" ]) && content.to_s.strip.present?

        { role: role.to_s, content: content.to_s.strip }
      end.last(12)
    end

    def low_signal_message?(message)
      normalized = message.downcase.gsub(/[^a-z0-9\s]/, "").squish
      return true if normalized.in?(LOW_SIGNAL_EXACT_MESSAGES)

      normalized.length < 4 && !message.include?("?")
    end

    def low_signal_response(message)
      normalized = message.downcase.gsub(/[^a-z0-9\s]/, "").squish
      if normalized.in?(TEST_MESSAGES)
        return "Your test came through. Ask me a real money question like “Can I leave my job?” or “Should I pay debt first?” and I’ll use your Household CFO context."
      end

      "Håfa Adai. I’m ready — tell me the money decision you want to work through, or choose one of the quick questions."
    end

    def fallback_response(message)
      "I’d start by protecting the household baseline first. For \"#{message}\", check three numbers: monthly cushion, emergency runway, and whether this move creates more optionality than stress."
    end
  end
end
