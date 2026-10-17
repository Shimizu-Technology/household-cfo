# Backstop for 32-bit cents columns. Participant inputs are already limited to
# HouseholdFinance::Money::MAX_AMOUNT_CENTS when parsed; this keeps any other
# path (Mia cards, imports, internal cents) from reaching the database with a
# value it cannot store, which would otherwise surface as a 500.
module BoundedCents
  extend ActiveSupport::Concern

  INT4_MAX = 2_147_483_647

  class_methods do
    def bounded_cents(*attributes)
      validate do
        attributes.each do |attribute|
          value = read_attribute_before_type_cast(attribute)
          next if value.nil?

          number = value.is_a?(Numeric) ? value.to_i : Integer(value.to_s, exception: false)
          next if number.nil? || number.abs <= INT4_MAX

          errors.add(:base, HouseholdFinance::Money.too_large_message("Amounts"))
          break
        end
      end
    end
  end
end
