module HouseholdFinance
  # Mia's whole reply on a setup turn. It is built from what Ruby just changed,
  # so every figure in it is already on the card.
  module MiaSetupCardReply
    QUESTIONS = {
      "household_name" => [ "What would you like to call your household?", "What name should go on your household plan?" ],
      "primary_goal" => [ "What's the main thing you'd like your money to do for your household?", "What would you most like this plan to help with?" ],
      "primary_income" => [ "About how much does your household bring home each month after taxes?", "What's your monthly take-home, roughly?" ],
      "fixed_expenses" => [ "What are your must-pay bills each month? One total or a list like rent 1500, power 140 both work.", "What do your regular bills come to each month?" ],
      "flexible_spend" => [ "About how much goes to everyday spending each month, like groceries and gas?", "What's your usual everyday spending in a month?" ],
      "debt_payment" => [ "What do you pay on debts each month? List each one with its minimum, or say no debts.", "Which debts do you have, and what's the minimum on each? You can say no debts." ]
    }.freeze
    HELP = {
      "household_name" => "A household name is just a label you choose, like your family name.",
      "primary_goal" => "A goal is something you want your money plan to help with, like covering the bills or building a little cushion. It can start small, or you can say skip.",
      "primary_income" => "Monthly take-home is the money you actually receive after taxes in a usual month.",
      "fixed_expenses" => "Fixed essentials are the bills you need to cover every month, like rent and utilities.",
      "flexible_spend" => "Everyday spending is what you plan for things like groceries, gas and other costs that change month to month.",
      "debt_payment" => "This is the minimum you have to pay on each debt every month, not the balance you owe."
    }.freeze
    FIELD_NAMES = {
      "household_name" => "your household name", "primary_goal" => "your goal", "primary_income" => "income",
      "fixed_expenses" => "fixed essentials", "flexible_spend" => "everyday spending", "debt_payment" => "debts"
    }.freeze

    module_function

    def updated_text(updates, card, card_open: true)
      lines = []
      updates.group_by(&:field).each { |field, group| lines.concat(field_lines(field, group, card, card_open)) }
      lines.join(" ")
    end

    def skipped_text(fields)
      return if fields.empty?
      "No problem, we'll leave #{fields.map { |field| FIELD_NAMES.fetch(field) }.to_sentence} for later."
    end

    def help(field) = HELP.fetch(field)

    def question(field, card:, previous:)
      labels = card.unresolved_labels(field)
      return "#{labels.first.match?(/s\z/i) ? 'What are' : "What's"} #{labels.first.downcase} in a usual month? I only have it as #{unresolved_note(card, field)}." if labels.one?
      return "What are #{labels.to_sentence} in a usual month?" if labels.any?
      debts = field == MiaSetupCard::DEBT_FIELD ? card.debts_without_minimum : []
      return "What do you pay on debts in a usual month?" if debts == [ MiaSetupCard::PLACEHOLDER_DEBT ]
      return "What's the monthly minimum on #{debts.to_sentence.downcase}?" if debts.any?
      variants = QUESTIONS.fetch(field)
      previous == field ? variants.last : variants.first
    end

    PAYCHECK_QUESTION = "Sure, let's work it out. About how much is one paycheck after taxes, and how often do you get it: every week, every two weeks, or twice a month?".freeze
    PAYCHECK_FREQUENCY_QUESTION = "How often do you get that paycheck: every week, every two weeks, or twice a month?".freeze
    BIMONTHLY_QUESTION = "Do you mean twice a month, or every two months?".freeze
    CADENCE_PHRASES = { "weekly" => "Paid every week is 52 paychecks a year", "biweekly" => "Paid every two weeks is 26 paychecks a year", "quarterly" => "Four times a year", "twice_yearly" => "Twice a year", "yearly" => "Spread over a year" }.freeze

    def working(proposal)
      stated, monthly = money(proposal[:stated_cents]), money(proposal[:monthly_cents])
      sum = proposal[:times] == 1 ? "#{stated} ÷ 12" : "#{stated} × #{proposal[:times]} ÷ 12"
      "#{CADENCE_PHRASES.fetch(proposal[:cadence])}, so #{sum} comes to about #{monthly} a month. I put it on your card but didn't count it yet. Should I use #{monthly}, or is a usual month different?"
    end

    def finished(card)
      card ? "That's everything I need. Look over your card and tap Apply when it's right." : nil
    end

    private_class_method def self.unresolved_note(card, field)
      Array(card.fields.dig(field, "parts")).find { |part| !part["counted"] }&.fetch("note").to_s
    end

    private_class_method def self.field_lines(field, group, card, card_open)
      if field.in?(MiaSetupCard::TEXT_FIELDS)
        return group.flat_map { |update| update.action == :too_long ? single_lines(field, update, card_open) : [ field == "household_name" ? "I put #{update.label} as your household name." : "Your goal is on the card." ] }
      end
      lines = []
      added = group.select { |update| update.action == :added && update.cents }
      lines << "Added #{added.map { |update| phrase(update) }.to_sentence}." if added.any?
      group.reject { |update| update.action == :card_full }.each { |update| lines.concat(single_lines(field, update, card_open)) }
      full = group.select { |update| update.action == :card_full }.map { |update| update.label.downcase }
      lines << "Your card holds #{MiaSetupCard::MAX_PARTS} rows here, so I left #{full.to_sentence} off. You can combine a few, or give me one total." if full.any?
      if added.many? || group.any? { |update| update.action.in?(%i[changed removed]) }
        total = field == MiaSetupCard::DEBT_FIELD ? debt_total(card) : card.money_total(field)
        lines << "#{FIELD_NAMES.fetch(field).capitalize} #{field == 'primary_income' ? 'is' : 'are'} #{money(total)} so far." if total
      end
      lines.compact
    end

    private_class_method def self.single_lines(field, update, card_open)
      case update.action
      when :changed then update.cents ? [ "Changed #{update.label.downcase} to #{money(update.cents)}." ] : [ "Updated #{update.label.downcase}. It #{update.note}." ]
      when :removed then [ "Took out #{update.label.downcase}." ]
      when :added then update.cents ? [] : [ "Added #{update.label.downcase}. It #{update.note}." ]
      when :total then [ total_line(field, update) ]
      when :none then [ field == MiaSetupCard::DEBT_FIELD ? "Noted: no debts." : none_line(field) ]
      when :needs_monthly then [ "#{(update.label || FIELD_NAMES.fetch(field)).sub(/\A./, &:upcase)} still #{update.label.to_s.match?(/s\z/i) ? 'need' : 'needs'} a monthly amount (#{update.note}), so I didn't count it." ]
      when :no_breakdown then [ "I only have one total for #{FIELD_NAMES.fetch(field)} (#{money(update.cents)}), so I can't change #{update.label.downcase} by itself. What should the new total be?" ]
      when :not_found then [ card_open ? "I don't see #{update.label.downcase} on your card." : "I don't see #{update.label.downcase} in your saved numbers. Which one did you mean?" ]
      when :debt_on_file then [ "You have a debt saved, so I left debts as they are. Tell me which one is gone, or change it in My Money." ]
      when :combined then [ "#{update.note} is one row on your card, so I can't change #{update.label.downcase} by itself. What should that whole row be?" ]
      when :too_long then [ "That's a little long for #{FIELD_NAMES.fetch(field)}. Can you shorten it to #{update.cents} characters or fewer?" ]
      else []
      end
    end

    private_class_method def self.none_line(field)
      { "primary_income" => "Noted: no income right now.", "fixed_expenses" => "Noted: no must-pay bills.", "flexible_spend" => "Noted: no everyday spending." }.fetch(field)
    end

    private_class_method def self.total_line(field, update)
      amount = update.note ? "#{update.note}, so #{money(update.cents)} a month" : "#{money(update.cents)} a month"
      "#{FIELD_NAMES.fetch(field).capitalize}: #{amount}."
    end

    private_class_method def self.phrase(update) = "#{update.label.downcase} #{money(update.cents)}"

    private_class_method def self.debt_total(card)
      Array(card.debt_state["parts"]).reject { |part| part["removed"] || part["minimum_cents"].nil? }.sum { |part| part["minimum_cents"] }
    end

    private_class_method def self.money(cents)
      ActiveSupport::NumberHelper.number_to_currency(Money.dollars(cents), precision: cents % 100 == 0 ? 0 : 2)
    end
  end
end
