module HouseholdFinance
  module MonthTerms
    module_function

    def tokens
      @tokens ||= begin
        full_names = Date::MONTHNAMES.each_with_index.filter_map { |name, number| [ name.downcase, number ] if name }
        abbreviations = Date::ABBR_MONTHNAMES.each_with_index.filter_map { |name, number| [ name.downcase, number ] if name }
        (full_names + abbreviations + [ [ "sept", 9 ] ]).uniq.sort_by { |name, _number| -name.length }
      end
    end

    def pattern
      @pattern ||= tokens.map { |name, _number| Regexp.escape(name) }.join("|")
    end

    def number(name)
      tokens.find { |candidate, _number| candidate == name.to_s.downcase }&.last
    end

    def index(name)
      month_number = number(name)
      month_number ? month_number - 1 : nil
    end

    def detect(text)
      normalized = text.to_s.downcase
      tokens.find { |name, _number| normalized.match?(/\b#{Regexp.escape(name)}\b/) }
    end

    def detect_number(text)
      detect(text)&.last
    end

    def detect_index(text)
      month_number = detect_number(text)
      month_number ? month_number - 1 : nil
    end
  end
end
