# frozen_string_literal: true

module Mia
  # A length correction is still a new, untrusted model reply. Callers supply
  # their complete safety/grounding validator and sanitize each attempt.
  class ResponseShapeRewriter
    Result = Struct.new(:content, :rejection_reason, keyword_init: true)

    def self.call(content, persona:, user_message:, validator:, &rewrite)
      new(persona: persona, user_message: user_message, validator: validator, rewrite: rewrite).call(content)
    end

    def self.instruction(persona)
      return "" unless persona.respond_to?(:response_shape)

      shape = persona.response_shape
      "Use #{shape.fetch('min_sentences')}-#{shape.fetch('max_sentences')} sentences total, at most #{shape.fetch('max_characters')} characters. " \
        "Fit validation, necessary caveats, and one next step inside that range; do not add separate openings or disclaimers. " \
        "Safety and hardship instructions take precedence over this length."
    end

    def initialize(persona:, user_message:, validator:, rewrite:)
      @persona, @user_message, @validator, @rewrite = persona, user_message, validator, rewrite
    end

    def call(content)
      reason = rejection_reason(content)
      return Result.new(content: content, rejection_reason: reason) unless reason == :persona_response_shape

      log_counts(content)
      instruction = "Rewrite the previous answer. #{self.class.instruction(persona)} " \
        "Keep every fact, uncertainty, safety boundary, and the next step; add nothing. " \
        "Use plain text without markdown. Return only the rewritten answer."
      rewritten = rewrite.call(instruction)
      reason = rejection_reason(rewritten)
      log_counts(rewritten) if reason == :persona_response_shape
      Result.new(content: rewritten, rejection_reason: reason)
    end

    private

    attr_reader :persona, :user_message, :validator, :rewrite

    def rejection_reason(content)
      return :blank_response if content.blank?

      reason = validator.call(content)
      return reason if reason

      policy = ResponseShapePolicy.new(content, persona: persona)
      return :persona_response_format unless policy.format_valid?
      return :persona_response_shape unless safety_length_exempt? || policy.length_valid?

      nil
    end

    def safety_length_exempt?
      CrisisBoundary.matches?(user_message) || CrisisBoundary.hopeless?(user_message) ||
        HouseholdFinance::MiaCoachAnswerer.routing_priority(user_message).in?([ :hardship, :essential_skip ])
    end

    def log_counts(content)
      counts = ResponseShapePolicy.new(content, persona: persona).counts
      Rails.logger.info("[Mia::ResponseShapeRewriter] reason=persona_response_shape #{counts.map { |key, value| "#{key}=#{value}" }.join(' ')}")
    end
  end
end
