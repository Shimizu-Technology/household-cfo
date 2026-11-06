module SavingsChallenge
  # Outage compatibility for callers outside the conversation boundary. Normal
  # chat consumes ParticipantMessageReader facts directly, without reparsing.
  module SavingsReportText
    module_function

    def nothing_set_aside?(message)
      message.to_s.match?(/\A(?:nothing saved|nothing set aside|i saved nothing)(?: today)?[.!]?\z/i)
    end

    def plain_nothing_set_aside?(message) = nothing_set_aside?(message)
  end
end
