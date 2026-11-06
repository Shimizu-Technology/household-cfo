module HouseholdFinance
  module MessageReplyIntent
    def self.matches?(message, intent)
      return false unless defined?(ParticipantMessageReader::Current)

      current = ParticipantMessageReader::Current.reply_intent
      current && current[:message].to_s.squish == message.to_s.squish && current[:intent] == intent
    end
  end
end
