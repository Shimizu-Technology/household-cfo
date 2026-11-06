module HouseholdFinance
  # Private conversation state, never a financial scenario. Expiry is deliberately
  # not sliding: a brief reply must not keep an old disclosure alive indefinitely.
  class ParticipantCareState
    TTL = 48.hours
    REPORT_KINDS = %w[purchase set_aside withdrawal nothing_saved income].freeze

    def initialize(session, persona_context_id: nil)
      @session, @persona_context_id = session, persona_context_id
    end

    def active
      topic = @session.active_topic.to_h.deep_stringify_keys
      return unless topic["type"] == "care"
      expiry = Time.zone.parse(topic["expires_at"].to_s) rescue nil
      expiry ||= (@session.chat_messages.order(:id).last&.created_at || @session.updated_at) + TTL
      return topic if expiry > Time.current

      @session.update!(active_topic: {})
      nil
    end

    def transition(message, reading, history:)
      prior = active
      report = self.class.report?(message, reading)
      financial = MiaMonthAnswer.question?(message) || ::Mia::FinancialReadOnlyRequest.matches?(message) || PurchaseQuestionText.purchase_question?(message) || message.match?(/\A\s*how much (?:is|do i have) left(?: this month)?[?.! ]*\z/i)
      current = if reading.available
        reading.care? ? reading.care.to_sym : ParticipantCare.certain_kind(message)
      else
        ParticipantCare.kind(message)
      end
      recovered = !reading.available && message.match?(/\A\s*(?:all good now\b|(?:i|we)(?:['’]m|['’]re| am| are|m|re)? (?:doing|feeling) better now\b|(?:i|we) figured it out\b)/i)
      released = current.nil? && (recovered || report || reading.answer_field.present? || financial || (reading.available && reading.care_status.in?(%w[resolved new_topic])))
      if released
        archive(prior) if prior
        @session.update!(active_topic: {}) if prior
        return nil
      end
      return unless current || prior

      kind = prior && reading.care == "none" ? prior.fetch("care_kind") : (current || prior.fetch("care_kind"))
      kind = :food if current.in?([ :hardship, :essentials ]) && message.match?(/\b(?:food|hungry|eat|grocer\w*)\b/i)
      kind = :housing if current == :hardship && message.match?(/\brent\b/i)
      kind = :hardship if kind.to_s == "essentials"
      topic = prior || ParticipantCare.topic(kind, persona_context_id: @persona_context_id)
      topic = topic.merge("type" => "care", "care_kind" => kind.to_s,
        "disclosure" => prior&.fetch("disclosure", nil) || message.to_s.first(700),
        "last_question" => Array(history).reverse.find { |row| row[:role].to_s == "assistant" }&.fetch(:content, "").to_s.last(700))
      @session.update!(active_topic: topic)
      topic
    end

    def self.report?(message, reading)
      reading.facts.any? { |fact| REPORT_KINDS.include?(fact["kind"]) } ||
        (!reading.available && (MiaCoachAnswerer.spend_report_text?(message) || MoneyMovementText.savings_deposit?(message) || message.match?(/\b(?:put away|set aside|saved)\s+\$?\d/i)))
    end

    private

    def archive(topic)
      @session.update!(open_topics: (Array(@session.open_topics).reject { |row| row.to_h["type"] == "care" } + [ topic ]).last(8))
    end
  end
end
