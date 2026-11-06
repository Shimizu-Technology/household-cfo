module SavingsChallenge
  # Conservative convenience input, never an approval or a financial record.
  # Ambiguous amounts/dates and conditional plans remain ordinary conversation.
  #
  # Each savings movement keeps its own single-amount review.
  # Spending becomes a "daily_report" card: one or more purchases, or an
  # explicit no-spend day, that the participant checks and saves themselves.
  class ChatIntake
    # Shared literal-dollar syntax used by the explicit saved-entry correction.
    MONEY = /\$\s*((?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d{1,2})?(?![\d.,])#{HouseholdFinance::Money::CHAT_THOUSANDS_SOURCE}?)/.freeze

    def initialize(enrollment, message:, extractor: nil, reading: nil)
      @enrollment, @message, @extractor = enrollment, message.to_s, extractor
      @reading = reading || HouseholdFinance::ParticipantMessageReader.call(message: @message)
    end

    # Why a clearly reported day could not become a card (outside the window), or nil.
    attr_reader :rejection, :ambiguous_movement

    def call
      return unless @enrollment && !HouseholdFinance::MiaCoachAnswerer.prompt_injection?(@message)
      @rejections = []
      @intakes = structured_inputs
      if @intakes.empty? && !@reading.available && @message.match?(/\A(?:(?:(?:i|we) )?spent \$\d+(?:\.\d{1,2})? at [\p{L} '-]+ (?:today|yesterday)|no[ -]spend (?:today|yesterday))[.!]?\z/i)
        report = DailyReportParser.new(@enrollment, message: @message).call
        @intakes << report.report if report.found?
        @rejection = report.reason if report.status == :rejected
      end
      if @intakes.empty? && @message.match?(/\b(?:spend|spending|spent|buy|purchases)\b/i) && (source = no_spend_source)
        parsed = DailyReportParser.new(@enrollment, message: source).call
        @intakes << parsed.report if parsed.found? && parsed.report[:no_spend]
        @rejection = parsed.reason if parsed.status == :rejected && parsed.reason&.dig(:kind).in?(%i[before_start after_end future])
      end
      @intakes.first
    end

    def rejections
      @rejections.presence || [ @rejection ].compact
    end

    def intakes
      @intakes || []
    end

    private

    def no_spend_source
      return @message if @reading.available && !@reading.question
      # A question alone never asserts a check-in. Keep a separate explicit
      # no-spend sentence; during an outage require the whole message to be one.
      sentences = @reading.question ? @message.split(/(?<=[.!])\s+/) : [ @message ]
      sentences.find do |sentence|
        sentence.match?(/\A(?:no[ -]spend(?:ing)?|(?:i|we) (?:did not|didn['’]t) spend (?:anything|money))(?: (?:today|yesterday))?[.!]?\z/i)
      end
    end

    def structured_inputs
      inputs = @reading.facts.filter_map do |fact|
        next unless fact["kind"].in?(%w[set_aside withdrawal purchase])
        next if fact["amount"].blank?
        cents = HouseholdFinance::ParticipantMessageReader.amount_cents(fact.fetch("amount"))
        next unless cents.positive?
        day = HouseholdFinance::ParticipantReportDay.call(day: fact["day"], message: fact["source_text"].presence || (@reading.facts.many? ? "" : @message), today: @enrollment.local_today)
        if day.state == :missing && fact["kind"] != "purchase"
          @rejections << { question: "You mentioned #{ActionController::Base.helpers.number_to_currency(cents / 100.0)} set aside or taken out. Which day was that?" }
          next
        end
        date = day.state == :missing ? @enrollment.local_today : day.date
        if date && !date.between?(@enrollment.starts_on, [ @enrollment.ends_on, @enrollment.local_today ].min)
          @rejections << { kind: date < @enrollment.starts_on ? :before_start : date > @enrollment.ends_on ? :after_end : :future,
            date: date, today: @enrollment.local_today, starts_on: @enrollment.starts_on, ends_on: @enrollment.ends_on, movement: fact["kind"] }
          next
        end
        review_day = date&.iso8601 || ""
        if fact["kind"] == "purchase"
          { kind: "daily_report", local_on: review_day, date_required: date.nil?, no_spend: false,
            purchases: [ { amount_cents: cents, merchant: HouseholdFinance::PurchaseQuestionText.merchant_label(fact["merchant"]), purchased_on: review_day } ],
            feelings: HouseholdFinance::PurchaseReportParser.feelings(@message), approval_state: "unreviewed_input", counted: false }
        else
          withdrawal = fact["kind"] == "withdrawal"
          { kind: withdrawal ? "withdrawal" : "contribution", amount_cents: cents,
            signed_cents: withdrawal ? -cents : cents, effective_on: review_day, date_required: date.nil?,
            approval_state: "unreviewed_input", counted: false, new_money_confirmation_required: !withdrawal }
        end
      end
      @rejection = @rejections.first
      inputs.each { |input| input.delete(:date_required) unless input[:date_required] }
      savings, reports = inputs.partition { |input| input[:kind] != "daily_report" }
      @ambiguous_movement = savings.uniq.length != savings.length
      grouped = reports.group_by { |input| input[:local_on] }.values.map do |rows|
        rows.first.merge(purchases: rows.flat_map { |input| input[:purchases] })
      end
      savings.uniq + grouped
    end
  end
end
