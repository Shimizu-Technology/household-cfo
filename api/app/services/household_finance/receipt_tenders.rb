module HouseholdFinance
  # Reads how a receipt was paid from the text the receipt reader already
  # returns (the draft's evidence and warnings, then the receipt summary).
  #
  # Buying a gift card is spending. Paying later with a gift card, voucher,
  # store credit or rewards is not new money, so it must not count again
  # (Leon, 2026-11-19, decision 4). Only cash and cards are new money.
  #
  # This is deliberately conservative: it acts only when every payment line it
  # recognised adds up to the receipt total (within a cent) and at least one of
  # them is not new money. Anything else, including a refund to a gift card or
  # cash back, returns nil and the draft stays exactly as the reader proposed it.
  class ReceiptTenders
    Reading = Data.define(:receipt_total_cents, :new_money_cents, :paid_with) do
      def not_new_money_cents = receipt_total_cents - new_money_cents
    end

    PAYLOAD_KEY = "receipt_payment".freeze
    TOLERANCE_CENTS = 1
    MAX_TEXT = 1_000
    # The refund and cash-back guards read much further than the payment lines do.
    MAX_GUARD_TEXT = 20_000

    AMOUNT = /(?<![\d.])[-(]?\s*\$?\s*(\d{1,3}(?:,\d{3})+|\d+)\.(\d{2})(?![\d])\)?/
    # "a $150.00 voucher", "Paid with", "plus"... are joining words, not labels.
    SEGMENT_BREAK = /;|\n|\||,\s|\.(?:\s|\z)|\s+plus\s+|\s+and\s+|\s+then\s+/i

    # Money moving back onto a card is not a way she paid; leave the receipt alone.
    REFUND = /\b(refund(?:ed)?|return(?:ed)?|credited\s+(?:to|back)|issued\s+to|back\s+to|put\s+back)\b/i
    CASH_BACK = /\bcash\s*-?\s*back\b/i
    # Buying, loading or activating a gift card is an item she bought.
    GIFT_CARD_ITEM = /\b(purchase[ds]?|bought|buy|sold|activat\w*|load(?:ed)?|reload\w*|top\s*-?\s*up|new\s+card|item|qty|quantity)\b/i
    BALANCE_INFO = /\b(remaining|available|left|new\s+balance|ending\s+balance|balance\s+(?:after|remaining|left|now)|earned)\b/i
    CHANGE = /\bchange(?:\s+(?:due|given|back))?\b/i

    NOT_NEW_MONEY = [
      [ "voucher", /\bvouchers?\b/i ],
      [ "gift_card", /\bgift\s*-?\s*(?:cards?|certificates?|cert)\b|\bgiftcards?\b|\begift\b/i ],
      [ "store_credit", /\b(?:store|merchandise|in-?store)\s+credit\b|\bcredit\s+slip\b|\baccount\s+credit\b|\bstore\s+card\s+balance\b/i ],
      [ "rewards", /\b(?:rewards?|loyalty|points?)\b/i ]
    ].freeze
    NEW_MONEY = [
      [ "cash", /\bcash\b/i ],
      [ "card", /\b(?:debit|credit|visa|master\s*card|mastercard|amex|american\s+express|discover|jcb|apple\s*pay|google\s*pay|samsung\s*pay|paypal|tap\s+to\s+pay|contactless|chip|card)\b|\bending\s+(?:in\s+)?\d{4}\b|[x*]{2,}\s*\d{4}\b/i ]
    ].freeze
    WALLET_NAMED_CASH = /\bapple\s*cash\b|\bcash\s*app\b|\bcash\s*card\b/i

    PHRASES = {
      "voucher" => "a voucher",
      "gift_card" => "a gift card",
      "voucher_or_gift_card" => "a voucher or gift card",
      "store_credit" => "store credit",
      "rewards" => "rewards or points"
    }.freeze

    def self.read(total_cents:, texts:)
      new(total_cents: total_cents, texts: texts).call
    end

    # How much of the receipt was paid in cash (after any change), when its
    # payment lines add up to the total and at least one of them is cash. A
    # cash purchase names cash she already took out (decision 3), so the app
    # asks which withdrawal it came from. nil when the receipt doesn't say.
    def self.cash_cents(total_cents:, texts:)
      new(total_cents: total_cents, texts: texts).cash_cents
    end

    # Plain words for the card: what was paid how, and what she can choose.
    def self.presentation(draft)
      payment = draft.draft_payload.to_h[PAYLOAD_KEY]
      return nil unless payment.is_a?(Hash)

      total = payment["receipt_total_cents"].to_i
      new_money = payment["new_money_cents"].to_i
      others = Array(payment["paid_with"]).select { |tender| tender.is_a?(Hash) && tender["new_money"] == false }
      return nil unless total.positive? && others.any?

      paid_other = others.map { |tender| "#{money(tender['amount_cents'])} with #{PHRASES.fetch(tender['kind'], 'a gift card or voucher')}" }
      paid_other[0] = paid_other[0].sub(" with ", " was paid with ")
      paid_other_text = paid_other.to_sentence(two_words_connector: " and ", last_word_connector: " and ")
      counting = if draft.total_amount_cents == new_money then "new_money"
      elsif draft.total_amount_cents == total then "all"
      else "changed"
      end
      message = if new_money.zero?
        "All #{money(total)} was paid with #{others.map { |tender| PHRASES.fetch(tender['kind'], 'a gift card or voucher') }.uniq.to_sentence(two_words_connector: ' and ', last_word_connector: ' and ')}, so none of it is new money. Choose Not now to leave it out of your spending."
      else
        case counting
        when "new_money" then "#{paid_other_text}, so only the #{money(new_money)} #{new_money_place(payment)} counts. The receipt total was #{money(total)}."
        when "all" then "Counting all #{money(total)}, including the #{money(total - new_money)} paid with #{others.map { |tender| PHRASES.fetch(tender['kind'], 'a gift card or voucher') }.uniq.to_sentence(two_words_connector: ' and ', last_word_connector: ' and ')}."
        else "The receipt total was #{money(total)}. #{paid_other_text.sub(/\A./, &:upcase)}, so #{money(new_money)} was new money."
        end
      end
      splits = draft.transaction_draft_splits.sort_by(&:id)
      {
        receipt_total: Money.dollars(total),
        receipt_total_cents: total,
        new_money: Money.dollars(new_money),
        new_money_cents: new_money,
        counting: counting,
        message: message,
        count_all_label: ("Count all #{money(total)}" if new_money.positive? && counting != "all"),
        count_new_money_label: ("Count only #{money(new_money)}" if new_money.positive? && counting != "new_money"),
        count_all_splits: split_amounts(splits, "receipt_amount_cents", total),
        count_new_money_splits: split_amounts(splits, "new_money_amount_cents", new_money)
      }.compact
    end

    # What a receipt is compared with on the bank statement: its new money,
    # while the draft is still the receipt's new money or its full total. An
    # amount she typed herself is compared as typed.
    def self.match_amount_cents(draft)
      amount_for(draft.draft_payload, draft.total_amount_cents)
    end

    # The same for a purchase she already confirmed: its new money while it still counts the receipt's new money or
    # its full total ("Count all"), read from the receipt entry that confirmed it. Anything else, as it counts.
    def self.transaction_match_amount_cents(transaction, drafts = transaction.transaction_drafts)
      amounts = drafts.map { |draft| amount_for(draft.draft_payload, transaction.total_amount_cents) }.uniq
      amounts.one? ? amounts.first : transaction.total_amount_cents
    end

    def self.amount_for(payload, total_cents)
      payment = payload.to_h[PAYLOAD_KEY]
      return total_cents unless payment.is_a?(Hash)

      new_money = payment["new_money_cents"].to_i
      return total_cents unless new_money.positive? && total_cents.in?([ new_money, payment["receipt_total_cents"].to_i ])

      new_money
    end

    # The splits that make up `cents`, from what each split was on the receipt.
    # nil when the splits no longer line up with the receipt (she edited them).
    def self.split_amounts(splits, key, cents)
      return nil if cents.zero? || splits.empty?
      # Once she has edited the splits, neither snapshot describes them any more: offer neither.
      current = splits.map(&:amount_cents)
      return nil unless %w[receipt_amount_cents new_money_amount_cents].any? { |snapshot| splits.map { |split| split.metadata.to_h[snapshot] } == current }
      amounts = splits.map { |split| split.metadata.to_h[key] }
      return nil unless amounts.all? { |amount| amount.is_a?(Integer) && amount.positive? } && amounts.sum == cents

      splits.zip(amounts).map { |split, amount| { id: split.id, amount: Money.dollars(amount) } }
    end

    def self.new_money_place(payment)
      kinds = Array(payment["paid_with"]).select { |tender| tender.is_a?(Hash) && tender["new_money"] == true }.map { |tender| tender["kind"] }.uniq
      case kinds
      when [ "card" ] then "on your card"
      when [ "cash" ] then "in cash"
      else "of new money"
      end
    end

    def self.money(cents)
      ActiveSupport::NumberHelper.number_to_currency(Money.dollars(cents.to_i))
    end

    def initialize(total_cents:, texts:)
      @total_cents = total_cents.to_i
      @full_texts = Array(texts).filter_map { |text| text.to_s.unicode_normalize(:nfkc).squish.first(MAX_GUARD_TEXT).presence }
      @texts = @full_texts.map { |text| text.first(MAX_TEXT) }
    end

    def call
      return nil unless @total_cents.positive?
      # Read in full, not just the part the payment lines come from.
      return nil if @full_texts.any? { |text| refund_to_tender?(text) }
      # Cash back anywhere on the receipt changes what reached the bank; leave it as read.
      return nil if @full_texts.any? { |text| text.match?(CASH_BACK) }

      readings = @texts.filter_map { |text| reading_for(text) }
      return nil if readings.empty?
      # Two places on the receipt that disagree about the new money: don't guess.
      return nil unless readings.map(&:new_money_cents).uniq.length == 1

      readings.first
    end

    def cash_cents
      return nil unless @total_cents.positive?
      return nil if @full_texts.any? { |text| refund_to_tender?(text) || text.match?(CASH_BACK) }

      cash = @texts.filter_map { |text| reading_for(text, require_not_new_money: false) }
        .map { |reading| reading.paid_with.select { |tender| tender["kind"] == "cash" }.sum { |tender| tender["amount_cents"] } }.uniq
      # Two places on the receipt that disagree about the cash: don't guess.
      return nil unless cash.one? && cash.first.positive?

      [ cash.first, @total_cents ].min
    end

    private

    def refund_to_tender?(text)
      segments(text).any? { |segment| segment.match?(REFUND) && (tender_kind(segment) || segment.match?(/\bcard\b/i)) }
    end

    def reading_for(text, require_not_new_money: true)
      tenders = []
      change_cents = 0
      segments(text).each do |segment|
        amounts = segment.to_enum(:scan, AMOUNT).map { Regexp.last_match }
        next if amounts.empty?
        return nil if segment.match?(CASH_BACK)
        # A minus or bracketed amount is money going back, not a way she paid: don't guess.
        return nil if amounts.any? { |match| match[0].match?(/\A(?:-(?:\$\s*)?\d|\()/) }

        labelled(segment, amounts).each do |label, cents|
          if label.match?(CHANGE) && !NOT_NEW_MONEY.any? { |_, pattern| label.match?(pattern) }
            change_cents += cents
            next
          end
          kind, new_money = tender_kind(label)
          next unless kind

          tenders << { "kind" => kind, "label" => tender_label(label), "amount_cents" => cents, "new_money" => new_money }
        end
      end
      return nil if tenders.empty? || (require_not_new_money && tenders.none? { |tender| tender["new_money"] == false })

      if change_cents.positive?
        cash = tenders.select { |tender| tender["kind"] == "cash" }
        # Change only comes back from cash handed over.
        return nil unless cash.length == 1 && cash.first["amount_cents"] > change_cents

        cash.first["amount_cents"] -= change_cents
      end
      return nil unless (tenders.sum { |tender| tender["amount_cents"] } - @total_cents).abs <= TOLERANCE_CENTS

      not_new = tenders.reject { |tender| tender["new_money"] }.sum { |tender| tender["amount_cents"] }
      return nil if not_new > @total_cents

      Reading.new(receipt_total_cents: @total_cents, new_money_cents: @total_cents - not_new, paid_with: tenders)
    end

    def segments(text)
      text.split(SEGMENT_BREAK).map(&:strip).reject(&:empty?)
    end

    # Each amount with the words that name it. Receipt lines put the name
    # first ("Debit card 7302 $34.88"); sentences put the amount first
    # ("$34.88 on debit card 7302").
    def labelled(segment, amounts)
      amount_first = segment[0...amounts.first.begin(0)].gsub(/\b(?:paid|with|using|by|a|an|the|of|on|in)\b/i, "").strip.empty?
      amounts.each_with_index.map do |match, index|
        label = if amount_first
          segment[match.end(0)...(amounts[index + 1]&.begin(0) || segment.length)]
        else
          segment[(index.zero? ? 0 : amounts[index - 1].end(0))...match.begin(0)]
        end
        [ label.to_s.strip, cents(match) ]
      end
    end

    def cents(match)
      "#{match[1].delete(',')}#{match[2]}".to_i
    end

    def tender_kind(label)
      # A gift card she bought, or the balance left on one, is not a payment.
      not_new = NOT_NEW_MONEY.select { |_, pattern| label.match?(pattern) }.map(&:first)
      if not_new.any?
        return nil if label.match?(GIFT_CARD_ITEM) || label.match?(BALANCE_INFO)
        return [ "voucher_or_gift_card", false ] if not_new.include?("voucher") && not_new.include?("gift_card")

        return [ not_new.first, false ]
      end
      return nil if label.match?(BALANCE_INFO)
      # A wallet named "cash" is a card payment, not cash in hand.
      return [ "card", true ] if label.match?(WALLET_NAMED_CASH)

      NEW_MONEY.each { |kind, pattern| return [ kind, true ] if label.match?(pattern) }
      nil
    end

    def tender_label(label)
      label.gsub(/\b(?:paid|with|using|by|on|a|an|the)\b/i, " ").gsub(/[^[:alnum:]\/ &'-]/, " ").squish.first(60).presence&.then { |text| text[0].upcase + text[1..] }
    end
  end
end
