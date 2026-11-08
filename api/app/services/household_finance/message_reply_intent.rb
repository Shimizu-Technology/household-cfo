module HouseholdFinance
  module MessageReplyIntent
    def self.purchase_question?(message)
      return false unless defined?(ParticipantMessageReader)

      current = ParticipantMessageReader::Current
      semantic = current.message.to_s.squish == message.to_s.squish && current.reading&.respond_to?(:purchase_question) && current.reading.purchase_question.to_h["item"].present?
      semantic || matches?(message, "purchase_question") || PurchaseQuestionText.purchase_question?(message) ||
        message.to_s.match?(/\b(?:do|would|will)\s+(?:i|we)\s+have\s+enough\b[^.!?]{0,45}\bfor\s+(?:a[n]?\s+)?\$[\d,]+\s+\w+/i)
    end

    def self.known?(message)
      return false unless defined?(ParticipantMessageReader::Current)

      current = ParticipantMessageReader::Current.reply_intent
      current && current[:provided] && current[:message].to_s.squish == message.to_s.squish
    end

    def self.matches?(message, intent)
      return false unless defined?(ParticipantMessageReader::Current)

      current = ParticipantMessageReader::Current.reply_intent
      current && current[:message].to_s.squish == message.to_s.squish && current[:intent] == intent
    end
  end
end
