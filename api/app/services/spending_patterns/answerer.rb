module SpendingPatterns
  # Both household and challenge chats narrate observations from reviewed money,
  # never planned allocations. No financial writes are permitted on this path.
  class Answerer
    QUESTION = /\b(?:what|which|show|tell|help|see|notice|spot|find|look|analy[sz]e)\b/i.freeze
    PATTERN = /\b(?:spending|purchase|shopping)\s+(?:patterns?|habits?)\b|\bpatterns?\b.*\b(?:spending|purchases?|shopping)\b/i.freeze
    WRITE = /\b(?:set|change|update|move|create|add|delete|remove|apply|save|confirm|lower|raise|increase|decrease)\b/i.freeze

    def self.matches?(message)
      message.match?(QUESTION) && message.match?(PATTERN) && !message.match?(WRITE) &&
        !HouseholdFinance::MiaCoachAnswerer.prompt_injection?(message) &&
        !::Mia::CrisisBoundary.matches?(message) && !::Mia::CrisisBoundary.hopeless?(message) &&
        !HouseholdFinance::MoneyMovementText.food_insecurity?(message)
    end

    def initialize(household:, message:, persona:, history:, approved_content:, available_product_modules: nil)
      @household, @message, @persona, @history, @approved_content = household, message, persona, history, approved_content
      @available_product_modules = available_product_modules
    end

    attr_reader :supplied_content_context, :patterns

    def call
      @patterns = Analyzer.new(@household).call
      choices = @patterns[:candidate_changes].first(2)
      coverage = @patterns[:coverage]
      present = coverage[:months].select { |row| row[:spending_cents] }.map { |row| Date.iso8601("#{row[:month]}-01").strftime("%b") }
      missing = coverage[:months].any? { |row| row[:spending_cents].nil? }
      merchants = @patterns[:discretionary_merchants].first(2)
      @supplied_content_context = []
      if merchants.empty?
        return "I don’t have enough reviewed purchases in flexible categories to spot a pattern yet. You can review a statement or tell me about a few purchases to start. A store name alone doesn’t tell me what you needed."
      end
      window = missing ? "I only see purchases for #{present.to_sentence}" : "From #{present.first} to #{present.last} in the recorded purchases"
      flexible = merchants.map { |row| "#{row[:label]} (#{money(row[:total_cents])})" }
      observed = "#{window}, #{flexible.to_sentence} #{flexible.one? ? 'was your biggest flexible spend' : 'were your biggest flexible spends'}."
      cluster = @patterns[:small_purchase_clusters].first
      waterfall = cluster ? " #{cluster[:purchase_count]} small buys of #{money(cluster[:threshold_cents])} or less stacked up around #{cluster[:label]} — #{money(cluster[:total_cents])} altogether." : ""
      impact = choices.first
      estimate = impact ? " Spending half as much at #{impact[:merchant]} could free about #{money(impact[:monthly_impact_cents])} a month, based on the months recorded." : ""
      question = if choices.empty?
        "Would you feel comfortable looking at one of these purchases together?"
      else
        "Would you feel more comfortable cutting back on #{choices.map { |choice| choice[:merchant] }.join(' or ')}?"
      end
      narrator = Narrator.new(user_message: @message, persona: @persona, history: @history, approved_content: @approved_content,
        answer_packet: { kind: "household_patterns", write_state: "no_write", fallback_response: "#{observed}#{waterfall}#{estimate} #{question}",
          available_product_modules: @available_product_modules,
          verified_facts: { merchants: merchants, cluster: cluster, choices: choices, months_with_purchases: present, missing_months: missing } })
      answer = narrator.call
      @supplied_content_context = narrator.supplied_content_context
      answer
    end

    private

    def money(cents)
      whole, fraction = cents.divmod(100)
      "$#{whole}#{fraction.zero? ? '' : ".#{fraction.to_s.rjust(2, '0')}"}"
    end
  end
end
