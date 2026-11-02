module SpendingPatterns
  # Parse only periods we can honor completely. Never silently drop an unknown
  # date qualifier and substitute the latest recorded purchases.
  class RequestedPeriod
    Unsupported = Class.new(StandardError)
    MONTH = /Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?/i
    # "May" is also a modal verb ("patterns may I be missing"), so it only counts
    # as a month after a date introducer, before a day/year, or describing
    # spending ("my May spending patterns").
    MONTH_EXCEPT_MAY = /Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?/i
    MAY_AS_MONTH = /\b(?:in|for|during|over|across|on|from|since|before|after|until|of|last|this|next|early|late|mid)\s+may\b|\bmay\s+\d{1,4}\b|\bmay\s+(?:spending|purchases?|shopping|expenses?)\b/i
    TEMPORAL = /#{MAY_AS_MONTH}|\b(?:#{MONTH_EXCEPT_MAY}|months?|years?|weeks?|days?|quarters?|q[1-4]|spring|summer|autumn|fall|winter|today|yesterday|since|before|after|until|between|last|past|next|recent|\d{4})\b/i
    # "my October spending patterns" names the month before the subject.
    ATTRIBUTIVE = /\b(?:my|the|our)\s+(?<period>(?:#{MONTH})(?:\s+\d{4})?)\s+(?:spending|purchase|shopping)\s+(?:patterns?|habits?)\b/i
    SUFFIX = /\b(?<period>(?:this|last)\s+month|(?:the\s+)?last\s+\d+\s+months?|(?:#{MONTH})(?:\s+\d{4})?|\d{4}|\d{4}-\d{2}-\d{2}(?:\s+(?:to|through)\s+\d{4}-\d{2}-\d{2})?)\s*[?.!]*\z/i

    def initialize(message, today: Time.current.in_time_zone("Pacific/Guam").to_date)
      @message, @today = message.to_s.squish, today
    end

    def call
      return {} unless @message.match?(TEMPORAL)
      attributive = @message.match(ATTRIBUTIVE)
      if attributive && !"#{attributive.pre_match} #{attributive.post_match}".match?(TEMPORAL)
        return bounded(*month_range(attributive[:period]))
      end

      match = @message.match(SUFFIX)
      raise Unsupported unless match && !match.pre_match.match?(TEMPORAL)

      period = match[:period]
      # Calendar suffixes must follow a date introducer directly. Otherwise
      # "summer 2025" or "early January 2025" would silently widen the scope.
      relative = period.match?(/\A(?:this|last|the last)\s/i)
      introduced = match.pre_match.match?(/\b(?:in|for|during|over|across|on|from)\s+(?:(?:my|the)\s+)?\z/i)
      raise Unsupported unless relative || introduced
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
        start, finish = month_range(period)
      end
      bounded(start, finish)
    rescue Date::Error
      raise Unsupported
    end

    private

    def month_range(period)
      name, year = period.split
      month = Date::ABBR_MONTHNAMES.index { |label| label&.casecmp?(name.first(3)) }
      start = Date.new(year&.to_i || @today.year, month, 1)
      [ start, start.end_of_month ]
    rescue Date::Error
      raise Unsupported
    end

    def bounded(start, finish)
      finish = [ finish, @today ].min
      raise Unsupported unless start <= finish && (finish - start).to_i <= 366
      { from: start, to: finish }
    end
  end
end
