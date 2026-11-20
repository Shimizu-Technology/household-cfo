module HouseholdFinance
  # What Mia says about the one receipt she just sent: what was read, what will count, and what to
  # check on the card. Only facts on the draft; nothing is worked out from her message.
  module ReceiptDraftReply
    # A tender that isn't new money (decision 4). Her own words only say how she paid; the card decides.
    NOT_NEW_MONEY = /\b(?:vouchers?|gift\s*-?\s*cards?|gift\s+certificates?|store\s+credit|rewards?|loyalty|points)\b/i
    module_function

    def call(draft, message:)
      merchant = SpendingPatterns::MerchantName.call(draft.merchant).presence || "a shop whose name I couldn’t read"
      amount = draft.total_amount_cents ? Money.plain(draft.total_amount_cents) : "an amount I couldn’t read"
      date = draft.occurred_on ? ", dated #{draft.occurred_on.strftime('%b %-d, %Y')}" : ", with no readable date"
      parts = [ "Your receipt from #{merchant} reads #{amount}#{date}." ]
      if message.to_s.match?(NOT_NEW_MONEY)
        parts << "A voucher, gift card, store credit or rewards isn’t new money, so only what you paid by card or cash should count. Check the amount on the card before you approve it."
      end
      parts << "Nothing counts in your spending until you approve the card below."
      parts.join(" ")
    end
  end
end
