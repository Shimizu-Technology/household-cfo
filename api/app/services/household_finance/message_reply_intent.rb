module HouseholdFinance
  module MessageReplyIntent
    def self.purchase_question?(message)
      return false unless defined?(ParticipantMessageReader)

      current = ParticipantMessageReader::Current
      semantic = current.message.to_s.squish == message.to_s.squish && current.reading&.respond_to?(:purchase_question) && current.reading.purchase_question
      semantic || matches?(message, "purchase_question") || PurchaseQuestionText.purchase_question?(message) ||
        message.to_s.match?(/\b(?:buy|get|order|purchase|afford|for)\s+(?:a[n]?\s+)?\$[\d,]+\s+(?!this month|last month)\w+/i)
    end

    def self.matches?(message, intent)
      return false unless defined?(ParticipantMessageReader::Current)

      current = ParticipantMessageReader::Current.reply_intent
      current && current[:message].to_s.squish == message.to_s.squish && current[:intent] == intent
    end
  end
end
