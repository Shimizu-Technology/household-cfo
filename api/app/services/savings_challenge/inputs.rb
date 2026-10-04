module SavingsChallenge
  module Inputs
    MAX_CENTS = (2**63) - 1
    module_function

    def keys!(input, required:, optional: [])
      raise ArgumentError, "Savings input contains missing or unsupported fields" unless (required - input.keys).empty? && (input.keys - required - optional).empty?
    end

    def integer!(value, minimum: -MAX_CENTS, maximum: MAX_CENTS)
      raise ArgumentError, "Use exact integer cents or versions" unless value.instance_of?(Integer) && value.between?(minimum, maximum)
      value
    end

    def id!(value, nullable: false)
      return nil if nullable && value.nil?
      return integer!(value, minimum: 1) if value.instance_of?(Integer)
      raise ArgumentError, "Record identity is invalid" unless value.instance_of?(String) && value.match?(/\A[1-9]\d{0,18}\z/)
      integer!(Integer(value, 10), minimum: 1)
    end

    def date!(value)
      return value if value.instance_of?(Date)
      raise ArgumentError, "Use a valid YYYY-MM-DD date" unless value.instance_of?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/)
      Date.iso8601(value)
    rescue Date::Error
      raise ArgumentError, "Use a valid YYYY-MM-DD date"
    end

    def text!(value, required: false)
      value = "" if value.nil? && !required
      raise ArgumentError, "Review reason must be text of at most 500 characters" unless value.instance_of?(String) && value.length <= 500
      raise ArgumentError, "Explain this correction before approval" if required && value.strip.empty?
      value
    end

    def accepted!(value)
      raise ArgumentError, "Explicit participant acceptance is required" unless value == true
      true
    end

    def money!(value, nullable: false, positive: false)
      return nil if nullable && value.nil?
      integer!(value, minimum: positive ? 1 : -MAX_CENTS)
    end
  end
end
