module Mia
  module FinancialRestartRequest
    module_function

    def matches?(message, session:)
      content = message.to_s.squish
      return false if content.match?(/\b(?:do not|don't|don’t|never)\s+(?:reset|clear|start)\b/i)
      return false if content.match?(/\b(?:chat|conversation|explanation|answer|draft|question|message)\b/i) && !content.match?(/\b(?:financial|numbers|income|debts?|accounts?|budget|information|everything)\b/i)
      explicit = content.match?(/\b(?:reset|clear|erase|wipe|delete)\b.{0,100}\b(?:everything|all\s+(?:(?:of\s+)?(?:my|our|the)\s+)?(?:info(?:rmation)?|data|numbers|records)|(?:my|our)\s+(?:info(?:rmation)?|financial\s+(?:data|picture)|numbers))\b/i) ||
        content.match?(/\b(?:start\s+(?:over|from\s+scratch)|fresh\s+start)\b/i)
      continuation = session.active_topic.to_h["type"] == "financial_restart" && content.match?(/\A(?:everything|all(?:\s+(?:of\s+)?(?:the\s+)?(?:information|info|data|numbers)(?:\s+that\s+i\s+have)?)?|yes(?:\s+please)?)\s*[.!?]*\z/i)
      explicit || continuation
    end
  end
end
