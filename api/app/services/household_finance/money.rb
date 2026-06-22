module HouseholdFinance
  module Money
    module_function

    def dollars(cents)
      (cents.to_i / 100.0).round
    end

    def cents(value)
      decimal = BigDecimal(value.to_s.presence || "0")
      (decimal * 100).round.to_i
    rescue ArgumentError
      0
    end

    def monthly_cents(amount_cents, cadence)
      case cadence.to_s
      when "weekly"
        (amount_cents.to_i * 52 / 12.0).round
      when "biweekly"
        (amount_cents.to_i * 26 / 12.0).round
      when "semi_monthly"
        amount_cents.to_i * 2
      when "annual"
        (amount_cents.to_i / 12.0).round
      when "one_time"
        0
      else
        amount_cents.to_i
      end
    end
  end
end
