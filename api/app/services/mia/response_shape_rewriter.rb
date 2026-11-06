# frozen_string_literal: true

module Mia
  # A length correction is still a new, untrusted model reply. Callers supply
  # their complete safety/grounding validator and sanitize each attempt.
  class ResponseShapeRewriter
    Result = Struct.new(:content, :rejection_reason, :guard_result, keyword_init: true)

    def self.call(content, persona:, user_message:, validator:, repairable_claims: [], fixed_prefix: "", guard: nil, &rewrite)
      new(persona: persona, user_message: user_message, validator: validator, rewrite: rewrite, repairable_claims: repairable_claims, fixed_prefix: fixed_prefix, guard: guard).call(content)
    end

    def self.instruction(persona, fixed_prefix: "")
      return "" unless persona.respond_to?(:response_shape)

      shape = persona.response_shape
      prefix_count = ResponseShapePolicy.new(fixed_prefix, persona: persona).sentence_count
      minimum = [ shape.fetch("min_sentences") - prefix_count, 0 ].max
      maximum = [ shape.fetch("max_sentences") - prefix_count, 0 ].max
      remaining_characters = shape.fetch("max_characters") - fixed_prefix.length - (fixed_prefix.present? ? 1 : 0)
      return "The fixed figures use the available reply budget. Return no coaching; figures take priority over a question." if maximum.zero? || remaining_characters < 40
      prefix_instruction = fixed_prefix.present? ? "The server already supplies #{prefix_count} sentence(s). The complete reply must stay within #{shape.fetch('min_sentences')}-#{shape.fetch('max_sentences')} sentences. Return only the remaining coaching. " : ""
      sentence_instruction = fixed_prefix.present? ? "Use #{minimum}-#{maximum} coaching sentences" : "Use #{minimum}-#{maximum} sentences total"
      "#{prefix_instruction}#{sentence_instruction}, at most #{remaining_characters} characters. " \
        "Fit validation, necessary caveats, and one next step inside that range; do not add separate openings or disclaimers. " \
        "Safety and hardship instructions take precedence over this length."
    end

    def initialize(persona:, user_message:, validator:, rewrite:, repairable_claims: [], fixed_prefix: "", guard: nil)
      @guard = guard
      @persona, @user_message, @validator, @rewrite = persona, user_message, validator, rewrite
      @repairable_claims = repairable_claims.map(&:to_s)
      @fixed_prefix = fixed_prefix.to_s
    end

    def call(content)
      reason = rejection_reason(content)
      claim_repair = @repairable_claims.include?(reason.to_s)
      guard_repair = reason == :reply_guard && @guard_result.reasons.all? { |flag| ReplyGuard::FLAGS.include?(flag) && flag != "sensitive_moment" }
      return Result.new(content: content, rejection_reason: reason, guard_result: @guard_result) unless reason == :persona_response_shape || claim_repair || guard_repair

      log_counts(content, reason: reason)
      instruction = "Rewrite the previous answer. #{self.class.instruction(persona, fixed_prefix: @fixed_prefix)} " \
        "Keep every fact, uncertainty, safety boundary, and the next step; add nothing. Keep an explicit participant-decides statement when the previous reply contains one. " \
        "Use plain text without markdown. Return only the rewritten answer."
      if claim_repair
        instruction += " The previous answer failed the #{reason} check. Do not say or imply that the participant can afford a purchase or that it fits their budget. " \
          "Avoid the words afford, affordable, fits, works, and safe-to-spend, including in negative statements and questions. " \
          "Start with what can be established from the supplied facts, state what is unknown, then ask one practical question. The participant decides."
      end
      if guard_repair
        instruction += " The previous answer failed the reply guard categories: #{@guard_result.reasons.join(', ')}. Remove those unsupported claims. " \
          "Use only supplied facts and the participant's stated situation. Do not invent payment methods, borrowing costs, data access or completed actions."
      end
      rewritten = rewrite.call(instruction)
      reason = rejection_reason(rewritten)
      if reason == :persona_response_shape
        log_counts(rewritten)
        fitted = fit_to_shape(rewritten)
        if fitted
          rewritten = fitted
          reason = rejection_reason(fitted)
        end
      end
      Result.new(content: rewritten, rejection_reason: reason, guard_result: @guard_result)
    end

    private

    attr_reader :persona, :user_message, :validator, :rewrite

    # Server sentences take part of the reply budget and rewrites often overrun
    # by one. Remove a sentence without a decision boundary or practical action,
    # keep the closing question, and let the validators judge it. Anything longer gets its fallback.
    def fit_to_shape(content)
      return if @fixed_prefix.blank?

      sentences = content.to_s.split(ResponseShapePolicy::SENTENCE_BOUNDARY).compact_blank
      return if sentences.length < 3

      # Keep the participant's choice and practical actions. If every sentence
      # carries a boundary or an action, decline the fit and use the validated fallback.
      protected = /\b(?:yours?|you decide|you choose|your (?:call|choice|decision)|cannot|can['’]t|unknown|not known|before|remove|wait|check|protect|cover|set aside)\b/i
      index = ((1...(sentences.length - 1)).to_a + [ 0 ]).find { |position| !sentences[position].match?(protected) }
      return unless index

      sentences.delete_at(index)
      text = sentences.join(" ")
      text if ResponseShapePolicy.new([ @fixed_prefix, text ].compact_blank.join(" "), persona: persona).length_valid?
    end

    def rejection_reason(content)
      return :blank_response if content.blank?

      reason = validator.call(content)
      return reason if reason

      policy = ResponseShapePolicy.new([ @fixed_prefix, content ].compact_blank.join(" "), persona: persona)
      return :persona_response_format unless policy.format_valid?
      return :persona_response_shape unless safety_length_exempt? || policy.length_valid?

      @guard_result = @guard.call(content) if @guard
      return :reply_guard if @guard_result && !@guard_result.allowed?

      nil
    end

    def safety_length_exempt?
      CrisisBoundary.matches?(user_message) || CrisisBoundary.hopeless?(user_message) ||
        HouseholdFinance::MiaCoachAnswerer.routing_priority(user_message).in?([ :hardship, :essential_skip ])
    end

    def log_counts(content, reason: :persona_response_shape)
      return unless persona.respond_to?(:response_shape)

      counts = ResponseShapePolicy.new([ @fixed_prefix, content ].compact_blank.join(" "), persona: persona).counts
      Rails.logger.info("[Mia::ResponseShapeRewriter] reason=#{reason} #{counts.map { |key, value| "#{key}=#{value}" }.join(' ')}")
    end
  end
end
