module SavingsChallenge
  # Conservative convenience input, never an approval or a financial record.
  # Ambiguous amounts/dates and conditional plans remain ordinary conversation.
  #
  # Each savings movement keeps its own single-amount review.
  # Spending becomes a "daily_report" card: one or more purchases, or an
  # explicit no-spend day, that the participant checks and saves themselves.
  class ChatIntake
    MONEY = /\$\s*((?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d{1,2})?(?![\d.,])#{HouseholdFinance::Money::CHAT_THOUSANDS_SOURCE}?)/.freeze
    # Worth asking the extractor only when it could produce a card: a number, and
    # a spending verb or a place.
    PLACE = /\b(?:at|from)\s+[a-z]/i.freeze

    def initialize(enrollment, message:, extractor: nil, reading: nil)
      @enrollment, @message, @extractor = enrollment, message.to_s, extractor
      @reading = reading || HouseholdFinance::ParticipantMessageReader.call(message: @message)
    end

    # Why a clearly reported day could not become a card (outside the window), or nil.
    attr_reader :rejection, :ambiguous_movement

    def call
      return unless @enrollment && !HouseholdFinance::MiaCoachAnswerer.prompt_injection?(@message)
      @intakes = structured_inputs
      if @intakes.empty? && !@reading.available && @message.match?(/\A(?:(?:i|we) spent \$\d+(?:\.\d{1,2})? at [\p{L} '-]+ (?:today|yesterday)|no[ -]spend (?:today|yesterday))[.!]?\z/i)
        report = DailyReportParser.new(@enrollment, message: @message).call
        @intakes << report.report if report.found?
        @rejection = report.reason if report.status == :rejected
      end
      if @intakes.empty? && @message.match?(/\b(?:spend|spending|spent|buy|purchases)\b/i)
        parsed = DailyReportParser.new(@enrollment, message: @message).call
        @intakes << parsed.report if parsed.found? && parsed.report[:no_spend]
        @rejection = parsed.reason if parsed.status == :rejected && parsed.reason&.dig(:kind).in?(%i[before_start after_end future])
      end
      @intakes.first
    end

    def intakes
      @intakes || []
    end

    private

    def structured_inputs
      inputs = @reading.facts.filter_map do |fact|
        next unless fact["kind"].in?(%w[set_aside withdrawal purchase])
        date = fact["day"].blank? ? @enrollment.local_today : requested_date(fact["day"])
        unless date && date.between?(@enrollment.starts_on, [ @enrollment.ends_on, @enrollment.local_today ].min)
          @rejection = if date
            { kind: date < @enrollment.starts_on ? :before_start : date > @enrollment.ends_on ? :after_end : :future,
              date: date, today: @enrollment.local_today, starts_on: @enrollment.starts_on, ends_on: @enrollment.ends_on }
          else
            { question: "Which day was that? Open Savings to review any earlier entry." }
          end
          next
        end
        cents = HouseholdFinance::ParticipantMessageReader.amount_cents(fact.fetch("amount"))
        next unless cents.positive?
        if fact["kind"] == "purchase"
          { kind: "daily_report", local_on: date.iso8601, no_spend: false,
            purchases: [ { amount_cents: cents, merchant: fact["merchant"], purchased_on: date.iso8601 } ],
            feelings: HouseholdFinance::PurchaseReportParser.feelings(@message), approval_state: "unreviewed_input", counted: false }
        else
          withdrawal = fact["kind"] == "withdrawal"
          { kind: withdrawal ? "withdrawal" : "contribution", amount_cents: cents,
            signed_cents: withdrawal ? -cents : cents, effective_on: date.iso8601,
            approval_state: "unreviewed_input", counted: false, new_money_confirmation_required: !withdrawal }
        end
      end
      savings, reports = inputs.partition { |input| input[:kind] != "daily_report" }
      @ambiguous_movement = savings.uniq.length != savings.length
      grouped = reports.group_by { |input| input[:local_on] }.values.map do |rows|
        rows.first.merge(purchases: rows.flat_map { |input| input[:purchases] })
      end
      savings.uniq + grouped
    end

    def requested_date(message)
      exact = message.scan(/\b\d{4}-\d{2}-\d{2}\b/)
      relative = message.scan(/\b(?:today|yesterday)\b/i).map(&:downcase).uniq
      return unless exact.length + relative.length == 1
      return Date.iso8601(exact.sole) if exact.any?
      @enrollment.local_today - (relative.sole.downcase == "yesterday" ? 1 : 0)
    rescue Date::Error
      nil
    end
  end
end
