module SavingsChallenge
  # The old amount identifies an approved entry; the new amount is only an
  # input for the existing review form. Ambiguous matches never pick a record.
  class SavingsCorrection
    def initialize(enrollment, message:)
      @enrollment, @message = enrollment, message
    end

    def call
      return unless @message.match?(/\b(?:actually|correct|fix|really|meant)\b/i) && @message.match?(/\b(?:set aside|saved|reserved|put aside)\b/i)
      values = @message.scan(ChatIntake::MONEY).flatten
      return { answer: "Which saved amount needs fixing, and what should it be instead? Nothing has changed." } unless values.length == 2
      old, replacement = values.map { |value| HouseholdFinance::Money.chat_cents(value) }
      entries = @enrollment.savings_entries.includes(:current_approved_version).select do |entry|
        version = entry.current_approved_version
        version && version.signed_cents == old && version.funding_source.in?(HouseholdFinance::SavingsProjection::ELIGIBLE_FUNDING_SOURCES)
      end
      return { answer: "I couldn't identify one saved #{money(old)} entry to fix. Open Savings and choose the entry, or tell me its date. Nothing has changed." } unless entries.one? && replacement.between?(1, 2_147_483_647)
      entry = entries.sole
      version = entry.current_approved_version
      { answer: "Replace #{money(old)} with #{money(replacement)}? Review the correction below; your total stays the same until you confirm.",
        intake: { kind: "contribution", amount_cents: replacement, signed_cents: replacement, effective_on: version.effective_on.iso8601,
          approval_state: "unreviewed_input", counted: false, new_money_confirmation_required: false,
          correction: ParticipantSerializer.record(entry), reason: "Corrected the amount from #{money(old)} to #{money(replacement)} in chat" } }
    end

    private

    def money(cents) = "$#{format('%.2f', cents / 100.0)}"
  end
end
