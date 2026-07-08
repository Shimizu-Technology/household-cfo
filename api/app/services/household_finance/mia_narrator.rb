# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module HouseholdFinance
  class MiaNarrator
    OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"
    DEFAULT_MODEL = "~anthropic/claude-sonnet-latest"
    MAX_PACKET_BYTES = 12_000
    MAX_HISTORY_MESSAGES = 8
    MAX_OUTPUT_TOKENS = 512
    OPEN_TIMEOUT_SECONDS = 5
    READ_TIMEOUT_SECONDS = 10
    BANNED_OPENERS = /\A(?:(?:(?:that['’]s|that is|this is) a )?(?:good|smart|great) question[.!]?)\s*/i
    DANGEROUS_WRITE_CLAIMS = [
      /\b(?:i|i['’]ve|i have|we|we['’]ve|we have|mia)\s+(?:already\s+|just\s+)?(?:added|recorded|logged|posted|tracked|deducted|applied|updated)\b/i,
      /\b(?:actuals?|month-to-date actuals?|mtd actuals?|budget actuals?)\s+(?:now\s+)?(?:show|include|reflect)\b/i,
      /\b(?:actuals?|month-to-date actuals?|mtd actuals?|budget actuals?)\s+(?:have|has|were|was|are|is)?\s*(?:now\s+)?(?:been\s+)?(?:updated|changed|deducted|applied|recorded|posted|logged|tracked)\b/i,
      /\b(?:this|that|the)\s+(?:transaction|purchase|charge|payment|receipt|spend|spending)\s+(?:has\s+(?:now\s+)?been|was|is\s+now|is)\s+(?:added|recorded|logged|posted|tracked|deducted|applied)\b/i
    ].freeze

    def initialize(user_message:, answer_packet:, history: [], api_key: ENV["OPENROUTER_API_KEY"], model: ENV.fetch("OPENROUTER_MIA_MODEL", ENV.fetch("OPENROUTER_MODEL", DEFAULT_MODEL)), persona: ::Mia::Persona.default)
      @user_message = user_message.to_s.squish
      @answer_packet = normalized_packet(answer_packet)
      @history = Array(history)
      @api_key = api_key.to_s.strip
      @model = model.to_s.strip.presence || DEFAULT_MODEL
      @persona = persona
    end

    def call
      return fallback_response if api_key.blank?
      return fallback_response if fallback_response.blank?

      narrated = openrouter_response
      sanitized = sanitize_narration(narrated)
      return fallback_response if sanitized.blank?
      return fallback_response if false_write_claim?(sanitized)

      sanitized
    rescue StandardError => e
      Rails.logger.warn("[HouseholdFinance::MiaNarrator] narration fallback: #{e.class}: #{e.message}")
      fallback_response
    end

    private

    attr_reader :user_message, :answer_packet, :history, :api_key, :model, :persona

    def openrouter_response
      uri = URI(OPENROUTER_URL)
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{api_key}"
      request["Content-Type"] = "application/json"
      request["HTTP-Referer"] = "https://github.com/Shimizu-Technology/household-cfo"
      request["X-Title"] = "Household CFO Method Mia Narrator"
      request.body = payload.to_json

      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, read_timeout: READ_TIMEOUT_SECONDS, open_timeout: OPEN_TIMEOUT_SECONDS) do |http|
        http.request(request)
      end
      return unless response.is_a?(Net::HTTPSuccess)

      parsed = JSON.parse(response.body)
      choice = parsed.dig("choices", 0)
      return if choice&.fetch("finish_reason", nil).to_s == "length"

      choice&.dig("message", "content")
    rescue JSON::ParserError
      nil
    end

    def payload
      {
        model: model,
        messages: [
          { role: "system", content: ::Demo::MiaResponder::SAFETY_SYSTEM_PROMPT },
          { role: "system", content: persona.system_prompt },
          { role: "system", content: narrator_contract },
          *conversation_history,
          { role: "user", content: narration_request }
        ],
        max_tokens: MAX_OUTPUT_TOKENS,
        temperature: 0.45
      }
    end

    def narrator_contract
      <<~PROMPT.squish
        You are Mia's narration layer. Rails has already computed the financial truth in ANSWER_PACKET_JSON.
        Rewrite the fallback_response in Mia's voice: warm, direct, Chamorro-grounded when earned, and Household CFO-minded.
        Preserve every concrete fact, amount, date, merchant, category, status, and pending-vs-confirmed distinction from the packet.
        Do not invent balances, transactions, due dates, categories, document findings, memories, or external facts.
        Do not claim you added, recorded, logged, deducted, applied, or updated a transaction unless the packet write_state is confirmed_write.
        For transaction_lookup or spending_report packets, you may describe existing historical rows as confirmed or on record, but do not imply a new write happened.
        If write_state is pending_review or no_write, say the Household CFO must review/confirm before actuals change.
        Reply in plain text only, 3-5 sentences, no markdown, no bullets, no heading, no generic opener.
      PROMPT
    end

    def narration_request
      <<~PROMPT.squish
        USER_MESSAGE:
        #{user_message}

        ANSWER_PACKET_JSON:
        #{packet_json}

        Write Mia's final response now.
      PROMPT
    end

    def packet_json
      json = JSON.generate(answer_packet)
      return json if json.bytesize <= MAX_PACKET_BYTES

      JSON.generate(answer_packet.slice(:kind, :basis, :write_state, :fallback_response, :guardrails))
    end

    def conversation_history
      history.filter_map do |message|
        role = message[:role] || message["role"]
        content = message[:content] || message["content"]
        next unless role.to_s.in?(%w[user assistant]) && content.to_s.strip.present?

        { role: role.to_s, content: content.to_s.strip.truncate(1_000, omission: "…") }
      end.last(MAX_HISTORY_MESSAGES)
    end

    def normalized_packet(packet)
      payload = packet.respond_to?(:deep_symbolize_keys) ? packet.deep_symbolize_keys : {}
      payload[:fallback_response] = payload[:fallback_response].to_s
      payload[:write_state] = payload[:write_state].presence || "no_write"
      payload[:guardrails] = Array(payload[:guardrails]) | default_guardrails
      payload
    end

    def default_guardrails
      [
        "participant_is_household_cfo",
        "mia_is_coach_assistant",
        "rails_owns_financial_truth",
        "pending_drafts_are_not_actuals",
        "review_before_apply"
      ]
    end

    def fallback_response
      answer_packet[:fallback_response].to_s
    end

    def sanitize_narration(content)
      content.to_s
        .sub(/\AMia:\s*/i, "")
        .sub(BANNED_OPENERS, "")
        .gsub(/Mia, your household CFO\.?/i, "Mia, your coach")
        .gsub(/Plan, don[’']t gamble\.?/i, "Protect the household baseline.")
        .gsub(/[\r\n]+/, " ")
        .squish
        .presence
    end

    def false_write_claim?(content)
      return false if answer_packet[:write_state] == "confirmed_write"

      DANGEROUS_WRITE_CLAIMS.any? { |pattern| content.match?(pattern) }
    end
  end
end
