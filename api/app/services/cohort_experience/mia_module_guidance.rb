# frozen_string_literal: true

require "delegate"
require "json"

module CohortExperience
  # Visibility limits product destinations, not the participant's ability to talk
  # about money or review a supervised change in chat.
  class MiaModuleGuidance
    ALIASES = {
      "review" => [ "Review", "Transactions" ],
      "budget" => [ "Budget" ],
      "profile" => [ "My Profile", "My Money", "Manual setup" ],
      "statements" => [ "Statements", "Files" ],
      "wealth" => [ "Wealth" ],
      "cfo_filter" => [ "CFO Filter" ],
      "optionality" => [ "Optionality" ]
    }.freeze

    def initialize(capabilities)
      @capabilities = capabilities.to_h.deep_symbolize_keys
    end

    # Wrap for this model call only; the published persona and its sealed bytes
    # remain untouched. This reaches the existing narrator/responder system role.
    def persona(persona)
      GuidedPersona.new(persona, context)
    end

    class GuidedPersona < SimpleDelegator
      def initialize(persona, context)
        super(persona)
        @module_context = context
      end

      def system_prompt
        "#{__getobj__.system_prompt}\nProduct navigation rule: only recommend enabled destinations from MODULE_CAPABILITIES_JSON. Never suggest opening hidden modules, their setup screens, or their uploads. Keep coaching about the money topic and supervised reviews here in chat. profile includes My Profile, My Money and Manual setup; statements includes Statements and Files; review includes Review and Transactions. MODULE_CAPABILITIES_JSON: #{JSON.generate(@module_context.except(:safety_note))}"
      end
    end

    def context
      {
        safety_note: "Only enabled modules may be suggested as product destinations. For disabled tools, keep coaching and supervised reviews in chat. Do not direct participants to hidden tabs, setup screens, or uploads. Module visibility does not prohibit discussing the underlying money topic.",
        enabled: modules.select { |item| item.fetch(:enabled) }.pluck(:id),
        disabled: modules.reject { |item| item.fetch(:enabled) }.pluck(:id)
      }
    end

    def filter(value)
      case value
      when Hash then value.transform_values { |entry| filter(entry) }
      when Array then value.map { |entry| filter(entry) }
      when String then filter_text(value)
      else value
      end
    end

    private

    attr_reader :capabilities

    def modules
      items = capabilities.fetch(:modules, [])
      return items if items.any? { |item| item[:id] == "statements" }

      # Schemas 1–3 exposed Statements through Profile. Project that historical
      # alias for the model without changing the sealed capability payload.
      profile = items.find { |item| item[:id] == "profile" }
      profile ? items + [ { id: "statements", enabled: profile.fetch(:enabled) } ] : items
    end

    def filter_text(text)
      disabled_ids = context.fetch(:disabled)
      names = disabled_ids.flat_map { |id| ALIASES.fetch(id, []) }
      return text if names.empty?

      destination = Regexp.union(names)
      filtered = text.gsub(/\b(?:open|visit|go to|head to|switch to|navigate to|return to)\s+(?:the\s+|your\s+)?["“']?(?:#{destination})\b["”']?(?:\s+(?:tab|screen|page|section|tool)\b)?/i, "keep working with me here in chat")
        .gsub(/\b(?:use|check)\s+(?:the\s+|your\s+)?["“']?(?:#{destination})\b["”']?\s+(?:tab|screen|page|section|tool)\b/i, "keep working with me here in chat")
      filtered = filtered.gsub(/\b(?:upload|add|review|finish|complete|enter|update)(\s+[^.!?\n]{0,80}?)?\s+(?:in|through|via|from)\s+(?:the\s+)?(?:#{destination})(?:\s+(?:tab|screen|page|section|tool))?\b/i) do
        "discuss#{Regexp.last_match(1)} here in chat"
      end
      if disabled_ids.include?("profile")
        filtered = filtered.gsub(/\b(?:finish|complete|fill out)\s+(?:the\s+|your\s+)?Manual setup\b/i, "keep working with me here in chat")
      end
      hidden_tools = names & [ "CFO Filter", "Optionality" ]
      filtered = filtered.gsub(/\b(?:use|try|run (?:it|this|that) through)\s+(?:the\s+)?(?:#{Regexp.union(hidden_tools)})\b/i, "keep working with me here in chat") if hidden_tools.any?
      filtered = filtered.sub(/\A[a-z]/, &:upcase) if text.match?(/\A[A-Z]/) && filtered != text
      filtered
    end
  end
end
