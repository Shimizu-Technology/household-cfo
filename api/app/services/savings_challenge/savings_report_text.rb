module SavingsChallenge
  # Outage compatibility for callers outside the conversation boundary. Normal
  # chat consumes ParticipantMessageReader facts directly, without reparsing.
  module SavingsReportText
    module_function

    def movements(message)
      reading = HouseholdFinance::ParticipantMessageReader.call(message: message, api_key: "")
      reading.facts.map do |fact|
        { kind: "contribution", amount_cents: HouseholdFinance::Money.chat_cents(fact.fetch("amount").delete("$")), clause: message }
      end
    end

    def nothing_set_aside?(message)
      message.to_s.match?(/\A(?:nothing saved|nothing set aside|i saved nothing)(?: today)?[.!]?\z/i)
    end

    def plain_nothing_set_aside?(message) = nothing_set_aside?(message)
    def purchase_text(message) = message.to_s
  end
end
