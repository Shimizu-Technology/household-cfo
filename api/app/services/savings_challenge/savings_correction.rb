module SavingsChallenge
  # The old amount identifies an approved entry; the new amount is only an
  # input for the existing review form. Ambiguous matches never pick a record.
  class SavingsCorrection
    def initialize(enrollment, message:, reading: nil)
      @enrollment, @message, @reading = enrollment, message, reading
    end

    def call
      return if HouseholdFinance::ParticipantMoneyIntent.blocked?(@message, kind: :correction)
      correction = @reading&.savings_correction.to_h
      return unless correction.present? || @message.match?(/\b(?:actually|correct|fix|really|meant)\b/i) && @message.match?(/\b(?:set aside|saved|reserved|put aside)\b/i)
      values = correction.present? ? correction.values_at("old_amount", "new_amount") : @message.scan(ChatIntake::MONEY).flatten
      return { answer: "Which saved amount needs fixing, and what should it be instead? Nothing has changed." } unless values.length == 2
      old, replacement = values.map { |value| HouseholdFinance::ParticipantMessageReader.amount_cents(value) }
      return { answer: "That saved amount is already #{money(old)}. Nothing needs changing." } if old == replacement
      entries = @enrollment.savings_entries.includes(:current_approved_version).select do |entry|
        version = entry.current_approved_version
        version && version.signed_cents == old && version.funding_source.in?(HouseholdFinance::SavingsProjection::ELIGIBLE_FUNDING_SOURCES)
      end
      if correction["day"].present?
        day = HouseholdFinance::ParticipantReportDay.call(day: correction["day"], message: @message, today: @enrollment.local_today)
        entries.select! { |entry| entry.current_approved_version.effective_on == day.date }
      end
      return { answer: "I couldn't identify one saved #{money(old)} entry to fix. Open Savings and choose the entry, or tell me its date. Nothing has changed." } unless entries.one? && replacement.between?(1, 2_147_483_647)
      entry = entries.sole
      version = entry.current_approved_version
      { amounts: [ old, replacement ], answer: "Replace #{money(old)} with #{money(replacement)}? Review the correction below; your total stays the same until you confirm.",
        intake: { kind: "contribution", amount_cents: replacement, signed_cents: replacement, effective_on: version.effective_on.iso8601,
          approval_state: "unreviewed_input", counted: false, new_money_confirmation_required: false,
          correction: ParticipantSerializer.record(entry), reason: "Corrected the amount from #{money(old)} to #{money(replacement)} in chat" } }
    end

    private

    def money(cents) = HouseholdFinance::Money.plain(cents)
  end
end
