module SavingsChallenge
  # Financial facts come from approved participant records. Uploads and proposed
  # spending reductions never become saved cash through a chat answer.
  class CoachAnswerer
    def initialize(household:, user:, enrollment:, message:, attachments: [], daily_report: nil, daily_rejection: nil, savings_intake: nil)
      @household, @user, @enrollment, @message, @attachments = household, user, enrollment, message.to_s, attachments
      @savings_intake = savings_intake if savings_intake.is_a?(Hash) && savings_intake[:kind].in?(%w[contribution withdrawal])
      @daily_report = daily_report if daily_report.is_a?(Hash) && daily_report[:kind] == "daily_report"
      @daily_rejection = daily_rejection if daily_rejection.is_a?(Hash) && (daily_rejection[:date] || daily_rejection[:question])
    end

    LOAN_TOPIC = /\b(?:loans?|mortgage|lending|lender|credit score|credit report|borrow(?:ing)?)\b/i
    LOAN_EFFECT = /\b(?:help|helps|helping|affect|affects|improve|improves|boost|impact|qualify|qualifies|approve|approved|approval|looks? good|eligib\w*|application|apply|applying|chances?)\b/i
    CARD_BALANCE_QUESTION = /\b(?:how much|what(?:['’]s| is| do)|do i(?: still)? owe)\b.{0,60}\b(?:owe|balance)\b.{0,80}\b(?:cards?|debts?)\b|\b(?:how much|what(?:['’]s| is| do)|do i(?: still)? owe)\b.{0,60}\b(?:cards?|debts?)\b.{0,60}\b(?:owe|balance)\b|\bhow much\b.{0,30}\bi (?:still )?owe\b.{0,40}\b(?:cards?|debts?)\b/i
    PAYMENT_REPORT = /\b(?:paid|put|sent|payment|toward|towards)\b.{0,60}\$\s*\d|\$\s*\d.{0,60}\b(?:paid|payment|toward|towards)\b/i
    LOAN_PAYMENT_OR_BORROWING = /\b(?:loan|car|truck|student)\s+payments?\b|\bpay(?:ing)?\s+(?:off|down)\b|\bborrow(?:ing|ed)?\s+from\s+(?:my\s+)?(?:savings|challenge|account)\b/i
    BORROWING_FROM_SAVINGS = /\bborrow(?:ing|ed)?\s+from\s+(?:my\s+)?(?:savings|challenge)\b/i
    LOAN_REQUEST = /\b(?:loan|lend)\s+me\b/i
    # An explicit question about a bank lending decision wins even when the
    # message also mentions paying down debt.
    BANK_LOAN_DECISION = /\b(?:loan|mortgage|credit)\s+(?:application|approval|decision)s?\b|\b(?:approve|qualify)\b.{0,30}\b(?:loan|mortgage)\b/i
    LOAN_CONTEXT = /\b(?:bank|challenge|application|apply|applying|mortgage|eligib\w*|qualif\w*|approv\w*|credit (?:score|report)|lender|lending)\b/i
    CARD_RANKING_QUESTION = /\b(?:which|what)\s+(?:credit\s+)?(?:cards?|debts?)\b.{0,40}\b(?:first|next|most|pay)\b|\b(?:avalanche|snowball)\b|\bpay\b.{0,30}\b(?:cards?|debts?)\b.{0,20}\bfirst\b/i
    EXTRA_PAYMENT_QUESTION = /\bhow much extra\b|\bextra (?:payment|amount)\b/i
    CARD_OR_DEBT_WORD = /\b(?:cards?|debts?)\b/i
    PROTECTED_BASELINE = /\b(?:can.t afford|cannot afford|not enough|shortfall|behind on|skip (?:buying |eating |paying (?:for )?)?(?:food|meals|groceries|rent|medicine|medication|minimum)|go without (?:food|meals|groceries|medicine|medication)|stop paying|cut (?:food|meals|medicine|medication))\b|\b(?:income|pay|salary)\b.{0,100}\b(?:essentials?|rent|bills?)\b|\b(?:essentials?|rent|bills?)\b.{0,100}\b(?:income|pay|salary)\b/i
    HOPELESS_STEP = "One small step, only if it feels okay: you can skip today, and a day you skip just stays unknown, not a miss. A smaller target is fine too, and nothing in this challenge is an obligation."

    # Verified facts the narrator may quote (approved optional card records only).
    attr_reader :answer_facts

    # True when the answer is final and should not be rewritten by the model.
    def deterministic? = @deterministic == true

    def call
      return HouseholdFinance::MiaCoachAnswerer.prompt_injection_boundary if HouseholdFinance::MiaCoachAnswerer.prompt_injection?(@message)
      if ::Mia::CrisisBoundary.hopeless?(@message)
        # Food and essentials come first; the wellbeing check is still added when the reply is saved.
        return deterministic(food_insecurity_answer) if HouseholdFinance::MoneyMovementText.food_insecurity?(@message)
        return deterministic(protected_baseline_answer) if @message.match?(PROTECTED_BASELINE)
        return deterministic(hopeless_answer)
      end
      return privacy_answer if @message.match?(/\b(?:employer|sponsor|bank of guam|bog)\b.{0,100}\b(?:see|share|send|give|feelings?|balances?|statements?|transactions?)\b|\bwho\b.{0,40}\b(?:sees?|access|read)\b/i)
      return food_insecurity_answer if HouseholdFinance::MoneyMovementText.food_insecurity?(@message)
      return guarantee_answer if @message.match?(/\b(?:guarantee|guaranteed|eligibility|eligible for|approve (?:my|a) loan|bank endorsement)\b/i)
      return deterministic(loan_answer) if loan_decision_question?
      return protected_baseline_answer if @message.match?(PROTECTED_BASELINE)
      return "The recommended goal is $500 in new money you actually set aside over 90 days. You can use a smaller comfortable goal or postpone a target. You can start without a credit card, statements, a bank connection, or a full budget. Open Home to review the challenge and choose your next step." unless @enrollment
      private_context do
        return attachment_answer if @attachments.any?
        return deterministic(daily_report_answer) if @daily_report
        return deterministic(daily_rejection_answer) if @daily_rejection
        return deterministic(savings_intake_answer) if @savings_intake
        return deterministic(target_change_answer) if target_change?
        return deterministic(card_balance_answer) if @message.match?(CARD_BALANCE_QUESTION) && !@message.match?(PAYMENT_REPORT)
        return savings_answer if @message.match?(BORROWING_FROM_SAVINGS)
        if (@message.match?(CARD_RANKING_QUESTION) || (@message.match?(EXTRA_PAYMENT_QUESTION) && @message.match?(CARD_OR_DEBT_WORD))) && !@message.match?(PAYMENT_REPORT)
          ranking = card_ranking_answer
          return deterministic(ranking) if ranking
          return debt_answer
        end
        return debt_answer if @message.match?(/\b(?:credit cards?|debts?|interest|apr|payoff|minimum payment|(?:loan|car|truck|student) payments?)\b/i)
        return feeling_answer if @message.match?(/\b(?:feel|feeling|ashamed|embarrassed|guilty|overwhelmed|anxious)\b/i)
        return investment_answer if HouseholdFinance::MoneyMovementText.investment_purchase_report?(@message)
        return savings_answer if HouseholdFinance::MoneyMovementText.savings_deposit_report?(@message)
        return daily_answer if @message.match?(/\b(?:spent|bought|purchase|receipt|cash|no.sp[eai]nd|check.in|yesterday)\b/i)
        return savings_answer if @message.match?(/\b(?:saved|savings|set aside|reserved|withdrew|withdrawal|progress|goal|target)\b/i)
        baseline_answer
      end
    end

    private

    def loan_decision_question?
      return false if @message.match?(LOAN_REQUEST)
      return true if @message.match?(BANK_LOAN_DECISION) && @message.match?(LOAN_EFFECT)

      @message.match?(LOAN_TOPIC) && @message.match?(LOAN_EFFECT) && @message.match?(LOAN_CONTEXT) &&
        !@message.match?(LOAN_PAYMENT_OR_BORROWING) && !@message.match?(CARD_BALANCE_QUESTION)
    end

    def deterministic(text)
      @deterministic = true
      text
    end

    def private_context
      ApplicationRecord.transaction do
        @household.lock!
        @enrollment.reload
        AccessPolicy.new(household: @household, user: @user, cohort: @enrollment.cohort.reload, enrollment: @enrollment, lock: true).call!
        yield
      end
    end

    def money(cents)
      value = cents.to_i
      "#{value.negative? ? '-' : ''}$#{value.abs.div(100)}.#{value.abs.modulo(100).to_s.rjust(2, '0')}"
    end

    def privacy_answer
      "Participation does not give an employer or sponsor access to your balances, statements, purchases, chat or feelings. Your records are private by default; coach monetary summaries and selected details require separate choices in Privacy & reminders. Sponsor reporting uses fixed, coarse cohort summaries with suppression, not individual financial records. You choose what to share, and can revoke a grant. What access would you like to review?"
    end

    def food_insecurity_answer
      "Thank you for telling me; a week like this is hard, and it is not a failure on your part. Food comes first, ahead of the savings challenge, so pausing or lowering your savings to buy food is the right call; the $500 suggestion is not an obligation. It is okay to ask for help this week; your program team or a local food pantry can help you get through to payday. Would it help to list what is due before your next paycheck, so we can decide together what can be paused or moved so food comes first?"
    end

    def investment_answer
      "Buying crypto or stocks is not a purchase check-in, and it does not count as money reserved for the challenge. I cannot give licensed investment advice or tell you what to buy, sell, or hold. Keep money for food, housing, medication, utilities and required payments in cash you can reach. Would you like to check what is due before your next paycheck?"
    end

    def guarantee_answer
      "I cannot guarantee $500 saved, promise a financial outcome, or decide bank or loan eligibility. The challenge tracks new money you actually reserve and approve over your personal 90 days, less withdrawals. You own the choices, and can choose a smaller comfortable target or postpone it. Keep essentials and required payments protected. What would be manageable for you?"
    end

    def protected_baseline_answer
      "Protect food, housing, medication, utilities and required payments before trying to reach a savings target. If essentials already exceed available income, focus on stabilizing that shortfall and postpone savings or choose a smaller comfortable goal; the $500 suggestion is not an obligation. I have not verified your complete income, commitments or available cash from this message. We can review what is known and missing without requiring a full budget or changing any records. Which essential or due payment needs attention first?"
    end

    def attachment_answer
      reviewed = FinancialBaselines::Reader.new(@household, user: @user).current
      "Your upload is available for statement review. Extraction proposes rows; it does not approve spending or saved money. Open Statements to review the account, period, rows, transfers and any missing information, then review your spending baseline. You can keep using Today while that review is incomplete.#{reviewed[:approved_version] ? ' Your previously approved baseline stays in place until you approve a revision.' : ''}"
    end

    def hopeless_answer
      "#{::Mia::FallbackReply::HOPELESS_OPENING} #{HOPELESS_STEP}"
    end

    def loan_answer
      "The challenge is personal savings practice. It does not affect, and does not promise anything about, a loan decision at the bank, and I cannot speak for the bank's lending or tell you how they would see it. What it can do is help you build a saving habit you can see for yourself, at a pace that works for you. One small step: do today's short check-in, or tell me what feels like a comfortable savings amount. Which would you like?"
    end

    # Current approved optional cards (never drafts), nil when the tool is unavailable.
    def approved_cards
      comparison = Debt::Reader.new(@enrollment, user: @user).call
      comparison.fetch(:cards).reject { |row| row[:terms]["status"].in?(%w[archived paid_off]) || row[:terms]["balance_cents"] == 0 }
    rescue AccessPolicy::Unavailable
      nil
    end

    def card_balance_answer
      return card_tool_unavailable unless @enrollment
      cards = approved_cards
      return card_tool_unavailable if cards.nil?
      return "You have not approved any optional card with a balance yet, so I do not have a balance to share. From Home, open Optional card & debt review if you want to add one; it is optional and does not need a budget or bank link. Nothing is assumed in the meantime." if cards.empty?

      @answer_facts = { approved_optional_debt: cards.map { |row| { label: row[:label], balance_cents: row[:terms]["balance_cents"] } } }
      lines = cards.map { |row| card_balance_line(row) }
      unknown = cards.flat_map { |row| unknown_fields(row[:terms]) }.uniq
      unknown_note = unknown.any? ? " I do not have the #{unknown.to_sentence(last_word_connector: ' and ')} for #{cards.one? ? 'it' : 'every card'}, so #{unknown.one? ? 'that stays' : 'those stay'} unknown, not zero." : ""
      "#{cards.one? ? 'Your approved card' : 'Your approved cards'}: #{lines.join('; ')}.#{unknown_note} This is what you approved, not a live balance from the bank, so check your card statement for today's number. Would you like to update or add any card terms?"
    end

    def card_balance_line(row)
      terms = row[:terms]
      stale = row[:source_stale] ? " (its source changed since you approved it, so review it)" : ""
      amount = terms["balance_cents"].nil? ? "balance not entered" : "#{money(terms['balance_cents'])} as of #{terms['as_of_on']}"
      "#{row[:label]}, #{amount}#{stale}"
    end

    def unknown_fields(terms)
      [ ("interest rate (APR)" if terms["apr_bps"].nil?), ("minimum payment" if terms["minimum_payment_cents"].nil?), ("due date" if terms["due_on"].nil?) ].compact
    end

    def card_ranking_answer
      return nil unless @enrollment
      cards = approved_cards
      return nil if cards.blank?
      return nil unless cards.any? { |row| row[:terms]["apr_bps"].nil? || row[:terms]["minimum_payment_cents"].nil? }

      @answer_facts = { approved_optional_debt: cards.map { |row| { label: row[:label], balance_cents: row[:terms]["balance_cents"] } } }
      "I cannot rank your cards or suggest an extra amount yet, because I do not have the interest rate (APR) and minimum payment for #{cards.one? ? 'your approved card' : 'each approved card'}, and I would not guess them. If you want, add those from Optional card & debt review on Home and I can compare them with you. Either way, I will not set a payoff date, and what you pay on a card stays separate from the money you set aside for the challenge. Would you like to add those terms?"
    end

    def card_tool_unavailable
      "Optional card review is not available for you right now, so I do not have a card balance to share. You can continue the savings challenge without cards or a full budget."
    end

    def debt_answer
      if @message.match?(/\b(?:no (?:debts?|credit cards?)|(?:don.t|do not) have(?: a| any)? (?:debts?|credit cards?)|debt.free|without(?: a| any)? (?:debts?|credit cards?))\b/i)
        "You can participate without credit cards or debt. Start with a short daily check-in and a comfortable savings target; statements are optional. Only approved new money you set aside, minus withdrawals, counts toward the challenge."
      else
        comparison = Debt::Reader.new(@enrollment, user: @user).call
        cards = comparison.fetch(:cards).index_by { |row| row[:card_id] }
        @answer_facts = { approved_optional_debt: comparison.fetch(:cards).reject { |row| row[:terms]["status"] == "archived" }.map { |row| { label: row[:label], balance_cents: row[:terms]["balance_cents"] } } }
        balance_order = comparison.fetch(:snowball_order).map { |id| cards.fetch(id).fetch(:label) }
        rate_order = comparison.fetch(:avalanche_order).map { |id| cards.fetch(id).fetch(:label) }
        reviewed = if cards.empty?
          "You have not approved optional card terms yet. From Home, open Optional card & debt review to check balances, APRs, minimums and any promotional or separate-rate terms without setting up a full budget."
        else
          "Among your current eligible reviewed cards, the known-balance order is #{balance_order.any? ? balance_order.join(', ') : 'not established'}. The known single-rate APR order is #{rate_order.any? ? rate_order.join(', ') : 'not established'}. #{comparison[:stale_card_count]} card records have changed source facts; review them before comparing. Unknown APRs, unknown balances, promotions and separate-rate segments are not precise avalanche targets."
        end
        "#{reviewed} This optional list does not establish complete household debt coverage. Income, essentials, required payments and liquidity are not verified here, so I cannot recommend an extra-payment amount or promise a payoff date. Card payments and debt progress stay separate from money actually reserved for the savings challenge. Missing values stay unknown; paid-off and archived cards are excluded. What card term would you like to review?"
      end
    rescue AccessPolicy::Unavailable
      "Optional card-term review is not available in this program release. You can continue the savings challenge without cards or a full budget. Debt payments do not automatically count as saved money; review missing terms before considering a debt strategy."
    end

    def feeling_answer
      "You can leave feelings blank and still use the challenge. A short reflection can help you notice what was happening when you bought something and how you feel now. It is private by default, and changing it does not change a purchase or your savings. In Today, choose the purchase before adding or editing a reflection. What would make the next check-in feel manageable?"
    end

    def daily_answer
      "Tell me the amount, where and date, like \"$12 at Kings yesterday\", and I'll put it on a card for you to check and save. How you felt is optional. If you spent nothing, say \"no spending today\"; a day you skip just stays unknown."
    end

    # The card below the reply lists exactly what was read. Nothing is saved
    # until the participant taps Save, so this never claims a record changed.
    def daily_report_answer
      report = @daily_report
      if report[:no_spend]
        day = report[:local_on] == @enrollment.local_today.iso8601 ? "today" : "that day"
        # Feelings are kept with a purchase; a no-spend day has none to keep them with.
        feelings = @message.match?(/\b(?:feel|feels|feeling|felt)\b/i) ? " How you feel isn't saved with a no-spend day, but I'm glad you told me." : ""
        return "No spending #{day}. I've put it below — tap Save to record it. Nothing is saved until you do.#{feelings}"
      end
      purchases = report[:purchases]
      items = purchases.map { |row| row[:merchant].present? ? "#{money(row[:amount_cents])} at #{row[:merchant]}" : money(row[:amount_cents]) }
      missing = purchases.count { |row| row[:merchant].blank? }
      place = missing.zero? ? "" : " Add where you spent #{missing == 1 ? 'it' : 'each one'} on the card."
      feelings = report[:feelings] ? " How you felt is on the card too; it stays private." : ""
      heard = @message.match?(/\b(?:feel|feels|feeling|felt|stressed|anxious|guilty|worried|sad|upset|overwhelmed|ashamed)\b/i) ? "Thanks for telling me how you're feeling. " : ""
      "#{heard}Got it: #{items.to_sentence}.#{place}#{feelings} I've put #{purchases.one? ? 'it' : 'these'} below — check #{purchases.one? ? 'it' : 'them'} and tap Save. Nothing is saved until you do."
    end

    # A clearly reported day outside the personal window: say which and why.
    def daily_rejection_answer
      reason = @daily_rejection
      return "#{reason[:question]} Nothing was saved." if reason[:question]
      date, today = reason[:date], reason[:today]
      label = ->(day) { day.strftime("%a, %b %-d") }
      spending = date == today - 1 ? "yesterday's spending" : "spending from #{label.call(date)}"
      case reason[:kind]
      when :before_start
        "Your challenge started on #{label.call(reason[:starts_on])}, so I can't add #{spending} to it. Nothing was saved. You can tell me about today instead."
      when :after_end
        "Your challenge ended on #{label.call(reason[:ends_on])}, so I can't add #{spending} to it. Nothing was saved."
      else
        "#{label.call(date)} hasn't happened yet, so I can't add it. Nothing was saved. Tell me once it's done."
      end
    end

    def savings_answer
      projection = Projection.new(@enrollment).call
      plan = @enrollment.current_accepted_plan_version
      progress = if projection[:reporting_known]
        backed = projection[:evidence_supported_cents].to_i.positive? ? " #{money(projection[:evidence_supported_cents])} of that matches a statement." : ""
        "So far you've saved #{money(projection[:reported_cents])} to your challenge.#{backed}"
      else
        "You haven't saved any money to your challenge yet, so your progress isn't known yet. That's not the same as $0."
      end
      target = plan&.target_cents ? " Your goal is #{money(plan.target_cents)} over your 90-day challenge." : " You haven't picked a goal yet; you can keep checking in."
      waiting = SavingsEntryDraft.joins(:savings_entry).where(savings_entries: { savings_enrollment_id: @enrollment.id }, status: "pending").count
      target += " #{waiting} savings #{waiting == 1 ? 'record is' : 'records are'} waiting for you to save in Savings; #{waiting == 1 ? 'it doesn’t' : 'they don’t'} count until you do." if waiting.positive?
      "#{progress}#{target} Only new money you actually set aside counts, minus anything you take out. Spending less, refunds, debt payments and moving money you already had don't count on their own. To add money you set aside, open Savings and save it there; nothing counts until you do. Did you set aside new money, or are you thinking about a spending change?"
    end

    def label_day(iso)
      date = Date.iso8601(iso.to_s)
      today = @enrollment.local_today
      return "today" if date == today
      return "yesterday" if date == today - 1

      "on #{date.strftime('%a, %b %-d')}"
    rescue Date::Error
      ""
    end

    # The card below lists it; nothing is saved until the participant saves it.
    def savings_intake_answer
      amount = money(@savings_intake[:amount_cents])
      day = label_day(@savings_intake[:effective_on])
      if @savings_intake[:kind] == "withdrawal"
        "Got it: #{amount} taken out of your challenge savings #{day}. I've put it below — check it, then save it. Nothing is saved until you do."
      else
        "Got it: #{amount} set aside #{day}. I've put it below — check it, then save it to your challenge. Only new money you set aside counts, and nothing is saved until you do."
      end
    end

    TARGET_CHANGE = /\A\s*(?:please\s+)?(?:i\s+(?:want|would like)\s+to\s+)?(?:change|set|make|update|lower|raise|move|switch|drop|bump)\s+(?:(?:my|the|challenge|savings)\s+)*(?:goal|target)\b|\A\s*(?:please\s+)?change\s+it\s+to\s+\$?\s*\d.{0,40}\b(?:goal|target)\b/i.freeze

    def target_change?
      return false if @message.match?(/\?|\b(?:set\s+aside|put\s+aside|saved|reserved|withdrew|took)\b/i)

      @message.match?(TARGET_CHANGE) && !@message.match?(/\b(?:debt|credit card|card balance|household)\b/i)
    end

    # A goal change happens in Savings, where the participant saves it.
    def target_change_answer
      cents = @message[/\$\s*(\d[\d,]*(?:\.\d{1,2})?)/, 1]&.then { |value| HouseholdFinance::Money.chat_cents(value) rescue nil }
      lead = cents&.positive? ? "To make your challenge goal #{money(cents)}" : "To change your challenge goal"
      "#{lead}, open Savings, then Your target & spending choices. It changes once you save it there, and nothing has changed yet. A smaller goal is completely fine."
    end

    def baseline_answer
      state = FinancialBaselines::Reader.new(@household, user: @user).current
      version = state[:approved_version]
      return "Start with one purchase or one statement, whichever feels easier. In Statements, review the rows and choose a spending baseline; a partial or manual baseline is valid. You can begin Today without a full budget or credit card. What would you like to work on first?" unless version
      snapshot = version.snapshot
      coverage = version.coverage_status == "complete" && !state[:needs_revision] ? "approved complete selected window" : "approved #{version.coverage_status} window with coverage limits"
      patterns = snapshot.fetch("patterns")
      observed = snapshot["observed_spending_known"] ? " Reviewed net spending was #{money(patterns.fetch('net_spending_cents'))}." : " Spending is not fully known from these records."
      flexible = Array(patterns["categories"]).select { |category| category["eligible"] == true && category["net_cents"].to_i.positive? }.first(3)
      choices = flexible.map { |category| "#{category['name']} (#{money(category['net_cents'])} observed)" }
      prompt = choices.any? ? " You marked #{choices.join(', ')} as eligible to consider. Which could change comfortably while keeping essentials covered?" : " Which purchase or category would you feel comfortable reviewing? Merchant names alone do not tell me what was necessary."
      "Your #{coverage} covers #{version.window_start_on} through #{version.window_end_on}.#{observed}#{state[:needs_revision] ? ' New approved records changed the inputs; review a baseline revision before treating it as current.' : ''}#{prompt} A spending change is an estimate until you actually reserve and approve new savings."
    end
  end
end
