module SpendingPatterns
  # Parse only periods we can honor completely. Never silently drop an unknown
  # date qualifier and substitute the latest recorded purchases.
  class RequestedPeriod
    Unsupported = Class.new(StandardError)
    MONTH = /Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?/i
    TEMPORAL = /\b(?:#{MONTH}|months?|years?|weeks?|days?|quarters?|today|yesterday|since|before|after|until|between|last|past|next|recent|\d{4})\b/i
    SUFFIX = /\b(?<period>(?:this|last)\s+month|(?:the\s+)?last\s+\d+\s+months?|(?:#{MONTH})(?:\s+\d{4})?|\d{4}|\d{4}-\d{2}-\d{2}(?:\s+(?:to|through)\s+\d{4}-\d{2}-\d{2})?)\s*[?.!]*\z/i

    def initialize(message, today: Time.current.in_time_zone("Pacific/Guam").to_date)
      @message, @today = message.to_s.squish, today
    end

    def call
      return {} unless @message.match?(TEMPORAL)
      match = @message.match(SUFFIX)
      raise Unsupported unless match && !match.pre_match.match?(TEMPORAL)

      period = match[:period]
      if period.match?(/\Athis month\z/i)
        start, finish = @today.beginning_of_month, @today
      elsif period.match?(/\Alast month\z/i)
        start, finish = @today.prev_month.beginning_of_month, @today.prev_month.end_of_month
      elsif (count = period[/\Alast\s+(\d+)\s+months?\z/i, 1] || period[/\Athe last\s+(\d+)\s+months?\z/i, 1])
        raise Unsupported unless count.to_i.between?(1, 12)
        finish = @today.prev_month.end_of_month
        start = finish.beginning_of_month - (count.to_i - 1).months
      elsif period.match?(/\A\d{4}\z/)
        start, finish = Date.new(period.to_i, 1, 1), Date.new(period.to_i, 12, 31)
      elsif period.match?(/\A\d{4}-/)
        dates = period.split(/\s+(?:to|through)\s+/i).map { |date| Date.iso8601(date) }
        start, finish = dates.first, dates.last
      else
        name, year = period.split
        month = Date::ABBR_MONTHNAMES.index { |label| label&.casecmp?(name.first(3)) }
        start = Date.new(year&.to_i || @today.year, month, 1)
        finish = start.end_of_month
      end
      finish = [ finish, @today ].min
      raise Unsupported unless start <= finish && (finish - start).to_i <= 366
      { from: start, to: finish }
    rescue Date::Error
      raise Unsupported
    end
  end
end
