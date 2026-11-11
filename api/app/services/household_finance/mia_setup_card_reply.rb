module HouseholdFinance
  # Mia's whole reply on a change-card turn. It is built from what Ruby just
  # changed, so every figure in it is already on the card.
  module MiaSetupCardReply
    REGISTRY = HouseholdFieldRegistry
    QUESTIONS = REGISTRY::FIELDS.to_h { |field| [ field.key, field.questions ] }.freeze
    HELP = REGISTRY::FIELDS.to_h { |field| [ field.key, field.help ] }.freeze
    FIELD_NAMES = REGISTRY::FIELDS.to_h { |field| [ field.key, field.name ] }.freeze

    module_function

    def updated_text(updates, card, card_open: true, complete: false)
      lines = []
      updates.group_by(&:field).each { |field, group| lines.concat(field_lines(field, group, card, card_open, complete)) }
      lines.join(" ")
    end

    def skipped_text(fields)
      return if fields.empty?
      "No problem, we'll leave #{fields.map { |field| FIELD_NAMES.fetch(field) }.to_sentence} for later."
    end

    def help(field) = HELP.fetch(field)

    def question(field, card:, previous:)
      offer = card.offer_question_for(field)
      return offer if offer
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
    CADENCE_PHRASES = { "weekly" => "Every week is 52 times a year", "biweekly" => "Every two weeks is 26 times a year", "twice_monthly" => "Twice a month is 24 times a year",
      "quarterly" => "Four times a year", "twice_yearly" => "Twice a year", "yearly" => "Once a year" }.freeze

    # The working behind an offered figure, for "help me work it out".
    def working(proposal)
      monthly = money(proposal[:monthly_cents])
      if proposal[:kind] == :range
        return "Halfway between #{money(proposal[:low_cents])} and #{money(proposal[:high_cents])} is #{monthly}. Want to use #{monthly} for now? You can change it any time."
      end
      stated = money(proposal[:stated_cents])
      yearly = money(proposal[:stated_cents] * proposal[:times])
      return "#{stated} a year ÷ 12 is #{proposal[:exact] ? '' : 'about '}#{monthly} a month. Use #{monthly}?" if proposal[:times] == 1
      return "#{CADENCE_PHRASES.fetch(proposal[:cadence])}, so #{stated} × 2 = #{monthly} a month. Use #{monthly}?" if proposal[:times] == 24
      "#{CADENCE_PHRASES.fetch(proposal[:cadence])}, so #{stated} × #{proposal[:times]} = #{yearly} a year, and ÷ 12 is about #{monthly} a month. Use #{monthly}?"
    end

    def finished(card, complete: false)
      return unless card
      complete ? "Look over your card and tap Apply when it's right." : "That's everything I need. Look over your card and tap Apply when it's right."
    end

    # What she said, before Mia offers the month it comes to.
    def offer_lead(card, field)
      part = card.offer(field)
      return unless part
      return "Got it, somewhere from #{money(part['range'].first)} to #{money(part['range'].last)}." if part["range"]
      "Got it, #{money(part['stated_cents'])} #{MiaSetupCard::CADENCE_NOTES.fetch(part['cadence'], '')}.".sub(/ \.\z/, ".")
    end

    # She moved past the offered figure; it waits on the card, unasked.
    def parked(field, card)
      note = card.offer(field)&.fetch("note", nil).to_s.sub(/, (?:about )?\$[\d,.]+(?: a month)? if that's right\z/, "")
      "I'll leave #{FIELD_NAMES.fetch(field)} as #{note.presence || 'it is'} for now. You can tap it on the card any time."
    end

    # A number that would have replaced a row she set herself.
    def kept_edit(field, card:, amount_text:, suggestion:)
      kept = card.fields.dig(field, "value") || (cents = card.money_total(field) || card.fields.dig(field, "cents")) && money(cents)
      lead = kept ? "You set #{FIELD_NAMES.fetch(field)} to #{kept} on the card, so I kept it." : "I kept #{FIELD_NAMES.fetch(field)} as you set it on the card."
      what = amount_text ? "What's the #{amount_text} for" : "What's that number for"
      "#{lead} #{what}#{suggestion ? ", #{FIELD_NAMES.fetch(suggestion)} or something else" : ''}?"
    end

    # One plain sentence after Apply that says what changed.
    def applied_sentence(card)
      parts = card.rows.flat_map { |row| applied_parts(row) }
      return if parts.empty? || parts.length > 4
      "Done: #{parts.to_sentence}."
    end

    private_class_method def self.applied_parts(row)
      field = row[:key]
      name = FIELD_NAMES.fetch(field)
      case REGISTRY.kind(field)
      when :text then [ field == "household_name" ? "your household name is #{row[:value_text]}" : "your goal is saved" ]
      when :months then [ "#{name} is #{row[:value_text]}" ]
      when :balance then [ "#{name} is #{money(row[:total_cents])}" ]
      when :debts
        return [ "no debts" ] if row[:value_text] == "No debts"
        row[:parts].map { |part| part[:removed] ? "#{part[:label].downcase} is off your debts" : "#{part[:label].downcase} minimum is #{money(part[:cents])}" }.presence || [ "#{name} are #{money(row[:total_cents])} a month" ]
      else
        changes = row[:parts].map { |part| part[:removed] ? "#{part[:label].downcase} is off" : "#{part[:label].downcase} is #{money(part[:cents])}" }
        total = row[:total_cents] && "#{name} #{field.in?(REGISTRY::INCOME_KEYS) ? 'is' : 'are'} #{money(row[:total_cents])} a month"
        changes.length > 3 ? [ total ].compact : (changes + [ total ]).compact
      end
    end

    private_class_method def self.unresolved_note(card, field)
      Array(card.fields.dig(field, "parts")).find { |part| !part["counted"] && !part["removed"] }&.fetch("note").to_s
    end

    private_class_method def self.field_lines(field, group, card, card_open, complete)
      kind = REGISTRY.kind(field)
      if kind == :text
        return group.flat_map { |update| update.action == :too_long ? single_lines(field, update, card_open) : [ field == "household_name" ? "I put #{update.label} as your household name." : "Your goal is on the card." ] }
      end
      return group.flat_map { |update| update.action == :set ? [ "#{FIELD_NAMES.fetch(field).sub(/\A./, &:upcase)}: #{update.label} #{update.label == '1' ? 'month' : 'months'}." ] : [] } if kind == :months
      return group.flat_map { |update| update.action == :total ? [ "#{FIELD_NAMES.fetch(field).sub(/\A./, &:upcase)}: #{money(update.cents)}." ] : [] } if kind == :balance
      lines = []
      added = group.select { |update| update.action == :added && update.cents }
      lines << "Added #{added.map { |update| phrase(update) }.to_sentence}." if added.any?
      group.reject { |update| update.action.in?(%i[card_full kept_edit]) }.each { |update| lines.concat(single_lines(field, update, card_open)) }
      full = group.select { |update| update.action == :card_full }.map { |update| update.label.downcase }
      lines << "Your card holds #{MiaSetupCard::MAX_PARTS} rows here, so I left #{full.to_sentence} off. You can combine a few, or give me one total." if full.any?
      if added.many? || group.any? { |update| update.action.in?(%i[changed removed]) }
        total = field == MiaSetupCard::DEBT_FIELD ? debt_total(card) : card.money_total(field)
        verb = field.in?(REGISTRY::INCOME_KEYS) ? "is" : "are"
        lines << (complete ? "#{FIELD_NAMES.fetch(field).sub(/\A./, &:upcase)} would be #{money(total)} a month." : "#{FIELD_NAMES.fetch(field).sub(/\A./, &:upcase)} #{verb} #{money(total)} so far.") if total
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
      when :renamed then [ "#{update.note.sub(/\A./, &:upcase)}, #{money(update.cents)} a month." ]
      when :purchases_waiting then [ "#{update.label} has a purchase waiting for your review, so I haven't taken it off. Review that purchase first, then ask me again. Nothing changed." ]
      when :name_taken then [ "#{update.note.sub(/\A./, &:upcase)}. What should I call this new one? Nothing changed." ]
      when :no_breakdown then [ "I only have one total for #{FIELD_NAMES.fetch(field)} (#{money(update.cents)}), so I can't change #{update.label.downcase} by itself. What should the new total be?" ]
      when :not_found then [ card_open ? "I don't see #{update.label.downcase} on your card." : "I don't see #{update.label.downcase} in your saved numbers. Which one did you mean?" ]
      when :debt_on_file then [ "You have a debt saved, so I left debts as they are. Tell me which one is gone, or change it in My Money." ]
      when :combined then [ "#{update.note} is one row on your card, so I can't change #{update.label.downcase} by itself. What should that whole row be?" ]
      when :too_long then [ "That's a little long for #{FIELD_NAMES.fetch(field)}. Can you shorten it to #{update.cents} characters or fewer?" ]
      else []
      end
    end

    private_class_method def self.none_line(field)
      { "primary_income" => "Noted: no income right now.", "business_income" => "Noted: no business income right now.", "fixed_expenses" => "Noted: no must-pay bills.",
        "flexible_spend" => "Noted: no everyday spending." }.fetch(field) { "Noted: nothing for #{FIELD_NAMES.fetch(field)}." }
    end

    private_class_method def self.total_line(field, update)
      amount = update.note ? "#{update.note}, so #{money(update.cents)} a month" : "#{money(update.cents)} a month"
      "#{FIELD_NAMES.fetch(field).sub(/\A./, &:upcase)}: #{amount}."
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
