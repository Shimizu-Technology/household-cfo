module HouseholdFinance
  # Positive evidence that a reply answers the question. A question's position
  # in a chat cannot turn an unrelated fact into a household goal.
  module MiaSetupReply
    module_function

    def goal?(message)
      current = ParticipantMessageReader::Current
      current.reading&.answer_field == "primary_goal" && (current.message == message.to_s || current.reading.setup_answer["value"] == message.to_s)
    end
  end
end
