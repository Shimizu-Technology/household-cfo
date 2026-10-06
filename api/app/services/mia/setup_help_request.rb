module Mia
  module SetupHelpRequest
    module_function

    def matches?(message, session:)
      content = message.to_s.squish
      return false if content.match?(/\b(?:do not|don't|don’t|never)\s+(?:want\s+to\s+)?(?:help\s+(?:me|us)\s+(?:to\s+)?)?(?:fix|correct|reset|clear|start)\b/i)
      return true if content.match?(/\b(?:fix\s+(?:my|our|the)\s+setup|help\s+(?:me|us)\s+(?:to\s+)?correct\s+(?:my|our|the)\s+setup)\b/i)
      return false unless session.active_topic.to_h["type"] == "setup_help"

      content.match?(/\A(?:everything|all(?:\s+(?:of\s+)?(?:the\s+)?(?:information|info|data|numbers)(?:\s+that\s+i\s+have)?)?|yes(?:\s+please)?)\s*[.!?]*\z/i) ||
        FinancialRestartRequest.matches?(content, session: session)
    end
  end
end
