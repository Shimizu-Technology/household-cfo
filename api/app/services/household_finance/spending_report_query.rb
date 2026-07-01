module HouseholdFinance
  class SpendingReportQuery
    REPORT_TERMS = /\b(spending|spent|actuals?|transactions?|budget report|month|quarter|jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)\b/i

    def initialize(message, today: Date.current)
      @message = message.to_s.downcase.squish
      @today = today
    end

    def range
      return nil unless report_like?

      explicit_date_range || named_range || month_span_range || month_range
    end

    private

    attr_reader :message, :today

    def report_like?
      message.match?(REPORT_TERMS) && message.match?(/\b(how|what|show|report|spend|spent|actual|transaction|last|this|from|between|for|in)\b/i)
    end

    def explicit_date_range
      match = message.match(/(?:from|between)\s+(\d{4}-\d{2}-\d{2})\s+(?:to|and|through|-)\s+(\d{4}-\d{2}-\d{2})/)
      return unless match

      build_range(Date.iso8601(match[1]), Date.iso8601(match[2]))
    rescue ArgumentError
      nil
    end

    def named_range
      case message
      when /\blast month\b/
        date = today.prev_month
        build_range(date.beginning_of_month, date.end_of_month)
      when /\bthis month\b/, /\bmonth to date\b/, /\bmtd\b/
        build_range(today.beginning_of_month, today)
      when /\blast quarter\b/
        date = today.prev_month(3)
        start = quarter_start(date)
        build_range(start, start.end_of_quarter)
      when /\bthis quarter\b/, /\bqtd\b/
        start = quarter_start(today)
        build_range(start, today)
      when /\bthis year\b/, /\bytd\b/, /\byear to date\b/
        build_range(today.beginning_of_year, today)
      when /\blast year\b/
        date = today.prev_year
        build_range(date.beginning_of_year, date.end_of_year)
      end
    end

    def month_range
      month_name, month_number = month_tokens.find { |name, _number| message.match?(/\b#{Regexp.escape(name)}\b/) }
      return unless month_name

      year = year_near(month_name) || today.year
      start = Date.new(year, month_number, 1)
      build_range(start, start.end_of_month)
    end

    def month_span_range
      match = message.match(/\b(#{month_pattern})\b\s*(?:-|to|through)\s*\b(#{month_pattern})\b(?:\s+(\d{4}))?/)
      return unless match

      start_month = month_number(match[1])
      end_month = month_number(match[2])
      year = match[3]&.to_i || today.year
      start_date = Date.new(year, start_month, 1)
      end_year = end_month < start_month ? year + 1 : year
      end_date = Date.new(end_year, end_month, 1).end_of_month
      build_range(start_date, end_date)
    end

    def month_tokens
      @month_tokens ||= begin
        full_names = Date::MONTHNAMES.each_with_index.filter_map { |name, index| [ name.downcase, index ] if name }
        abbreviations = Date::ABBR_MONTHNAMES.each_with_index.filter_map { |name, index| [ name.downcase, index ] if name }
        (full_names + abbreviations + [ [ "sept", 9 ] ]).uniq.sort_by { |name, _number| -name.length }
      end
    end

    def month_pattern
      @month_pattern ||= month_tokens.map { |name, _number| Regexp.escape(name) }.join("|")
    end

    def month_number(name)
      month_tokens.find { |candidate, _number| candidate == name.downcase }&.last
    end

    def year_near(month_name)
      match = message.match(/\b#{Regexp.escape(month_name)}\b\s+(\d{4})/) || message.match(/\b(\d{4})\s+#{Regexp.escape(month_name)}\b/)
      match&.[](1)&.to_i
    end

    def quarter_start(date)
      month = (((date.month - 1) / 3) * 3) + 1
      Date.new(date.year, month, 1)
    end

    def build_range(start_on, end_on)
      return nil if end_on < start_on

      { start_on: start_on, end_on: end_on }
    end
  end
end
