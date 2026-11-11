module HouseholdFinance
  # A household change the intent model picked out of her message ("the visa
  # min is 95 now") becomes the same card changes the reader produces, so it
  # lands on the one change card instead of a second review. Every amount must
  # still be a figure she wrote; anything else is dropped.
  class MiaSetupCardIntent
    TYPES = %w[update_household_setup create_debt update_debt archive_debt schedule_income_change].freeze
    INCOME_CADENCES = { "monthly" => "monthly", "weekly" => "weekly", "biweekly" => "biweekly", "semi_monthly" => "twice_monthly" }.freeze

    def initialize(household, message:)
      @household = household
      @message = message.to_s
    end

    def changes(intent_result)
      actions = [ intent_result&.action, *Array(intent_result&.write_plan.to_h[:actions]).map { |item| item[:action] } ].compact.map { |action| action.to_h.deep_symbolize_keys }
      changes = {}
      actions.each { |action| add(changes, action) }
      changes.presence&.merge("skips" => [])
    end

    private

    attr_reader :household, :message

    def add(changes, action)
      case action[:type].to_s
      when "update_household_setup" then add_setup_values(changes, action[:setup_updates].to_h)
      when "create_debt", "update_debt" then add_debt(changes, action)
      when "archive_debt" then remove_debt(changes, action)
      when "schedule_income_change" then add_income(changes, action)
      end
    end

    def add_setup_values(changes, values)
      values.each do |key, value|
        key = key.to_s
        next unless HouseholdFieldRegistry.field?(key) && value.to_s.strip.present?
        case HouseholdFieldRegistry.kind(key)
        when :text then changes[key] = value.to_s.squish if quoted_text?(value)
        when :income, :bills
          cents = quoted_cents(value)
          changes[key] = { "total" => { "amount_cents" => cents, "cadence" => "monthly", "quote" => value.to_s } } if cents
        when :balance
          cents = quoted_cents(value)
          changes[key] = { "amount_cents" => cents } if cents
        when :months
          months = value.to_s.to_d
          changes[key] = { "months" => months.frac.zero? ? months.to_i.to_s : months.to_s("F") } if months.positive? && message.match?(/(?<![\d.])#{Regexp.escape(months.frac.zero? ? months.to_i.to_s : months.to_s('F'))}\s*(?:months?|mos?)\b/i)
        end
      end
    end

    def add_debt(changes, action)
      name = debt_name(action)
      return unless name
      minimum = quoted_cents(action[:minimum_payment])
      balance = quoted_cents(action[:amount])
      return unless minimum || balance
      debts = changes["debt_payment"] ||= { "parts" => [] }
      debts["parts"] << { "op" => action[:type] == "create_debt" ? "add" : "replace", "name" => name, "minimum_cents" => minimum, "balance_cents" => balance }.compact
    end

    def remove_debt(changes, action)
      name = debt_name(action)
      return unless name
      debts = changes["debt_payment"] ||= { "parts" => [] }
      debts["parts"] << { "op" => "remove", "name" => name }
    end

    def add_income(changes, action)
      return unless action[:entry_type].to_s == "recurring_change"
      source = household.income_sources.find_by(id: action[:income_source_id].to_i)
      field = source&.source_type == "business" ? "business_income" : "primary_income"
      cents = quoted_cents(action[:amount])
      cadence = INCOME_CADENCES[action[:cadence].to_s.presence || "monthly"]
      return unless cents && cadence
      entry = { "amount_cents" => cents, "cadence" => cadence, "quote" => action[:amount].to_s }
      entry = entry.merge("cadence" => "per_paycheck", "count" => 2, "stated_cadence" => "twice_monthly") if cadence == "twice_monthly"
      changes[field] = { "total" => entry }
    end

    # Saved debts are named by their saved label; a new one must be in her words.
    def debt_name(action)
      id = action[:debt_id].to_i
      return household.debts.find_by(id: id)&.label if id.positive?
      name = action[:debt_name].to_s.squish
      name if name.present? && message.downcase.include?(name.downcase)
    end

    def quoted_text?(value) = message.downcase.include?(value.to_s.squish.downcase)

    # The figure must be one she wrote, in any of its usual spellings.
    def quoted_cents(value)
      return if value.to_s.strip.blank? || value.to_s.strip.casecmp?("unknown")
      cents = Money.cents(value)
      return unless cents&.positive?
      cents if message.scan(/\$?\d[\d,]*(?:\.\d{1,2})?/).any? { |quote| ParticipantMessageReader.amount_cents(quote) == cents }
    rescue ArgumentError
      nil
    end
  end
end
