module SavingsChallenge
  # Financial facts come from approved participant records. Uploads and proposed
  # spending reductions never become saved cash through a chat answer.
  class CoachAnswerer
    def initialize(household:, user:, enrollment:, message:, attachments: [])
      @household, @user, @enrollment, @message, @attachments = household, user, enrollment, message.to_s, attachments
    end

    def call
      return HouseholdFinance::MiaCoachAnswerer.prompt_injection_boundary if HouseholdFinance::MiaCoachAnswerer.prompt_injection?(@message)
      return privacy_answer if @message.match?(/\b(?:employer|sponsor|bank of guam|bog)\b.{0,100}\b(?:see|share|send|give|feelings?|balances?|statements?|transactions?)\b|\bwho\b.{0,40}\b(?:sees?|access|read)\b/i)
      return guarantee_answer if @message.match?(/\b(?:guarantee|guaranteed|eligibility|eligible for|approve (?:my|a) loan|bank endorsement)\b/i)
      return protected_baseline_answer if @message.match?(/\b(?:can.t afford|cannot afford|not enough|shortfall|behind on|skip (?:food|meals|rent|medicine|medication|minimum)|stop paying|cut (?:food|meals|medicine|medication))\b|\b(?:income|pay|salary)\b.{0,100}\b(?:essentials?|rent|bills?)\b|\b(?:essentials?|rent|bills?)\b.{0,100}\b(?:income|pay|salary)\b/i)
      return "The recommended goal is $500 in new money you actually set aside over 90 days. You can use a smaller comfortable goal or postpone a target. You can start without a credit card, statements, a bank connection, or a full budget. Open Home to review the challenge and choose your next step." unless @enrollment
      private_context do
        return attachment_answer if @attachments.any?
        return debt_answer if @message.match?(/\b(?:credit cards?|debts?|interest|apr|payoff|minimum payment)\b/i)
        return feeling_answer if @message.match?(/\b(?:feel|feeling|ashamed|embarrassed|guilty|overwhelmed|anxious)\b/i)
        return daily_answer if @message.match?(/\b(?:spent|bought|purchase|receipt|cash|no.sp[eai]nd|check.in|yesterday)\b/i)
        return savings_answer if @message.match?(/\b(?:saved|savings|set aside|reserved|withdrew|withdrawal|progress|goal|target)\b/i)
        baseline_answer
      end
    end

    private

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
      "Participation does not give an employer or sponsor access to your balances, statements, purchases, chat or feelings. Your records are private by default; coach monetary summaries and selected details require separate choices in Privacy & notifications. Sponsor reporting uses fixed, coarse cohort summaries with suppression, not individual financial records. You choose what to share, and can revoke a grant. What access would you like to review?"
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

    def debt_answer
      if @message.match?(/\b(?:no (?:debts?|credit cards?)|(?:don.t|do not) have(?: a| any)? (?:debts?|credit cards?)|debt.free|without(?: a| any)? (?:debts?|credit cards?))\b/i)
        "You can participate without credit cards or debt. Start with a short daily check-in and a comfortable savings target; statements are optional. Only approved new money you set aside, minus withdrawals, counts toward the challenge."
      else
        comparison = Debt::Reader.new(@enrollment, user: @user).call
        cards = comparison.fetch(:cards).index_by { |row| row[:card_id] }
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
      "For a purchase, enter the amount, where and date in Today, then review it before approval. Feelings then and now are optional. If a receipt or statement shows the same purchase, link the reviewed record so it is counted once. Use an explicit no-spend check-in for a day with no purchases; an unanswered day remains unknown. Which day would you like to review?"
    end

    def savings_answer
      projection = Projection.new(@enrollment).call
      plan = @enrollment.current_accepted_plan_version
      progress = projection[:reporting_known] ? "Your approved reported progress is #{money(projection[:reported_cents])}. The evidence-supported subset is #{money(projection[:evidence_supported_cents])}; it is included in reported progress, never added to it." : "You have not yet approved a savings report for this window; progress is unknown."
      target = plan&.target_cents ? " Your accepted goal is #{money(plan.target_cents)} over your personal 90-day challenge." : " You have not accepted a money target yet; you can continue check-ins."
      "#{progress}#{target} Only new money actually set aside counts, minus withdrawals. Lower spending, refunds, debt payments and moving money already saved do not create progress. Open Home to review a contribution or withdrawal; a draft stays pending until you approve it. Have you actually reserved new money, or are you reviewing a spending change?"
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
