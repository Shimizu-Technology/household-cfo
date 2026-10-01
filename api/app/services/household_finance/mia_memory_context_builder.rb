module HouseholdFinance
  class MiaMemoryContextBuilder
    MAX_MEMORIES = 20

    def initialize(household, user:)
      @household = household
      @user = user
    end

    def call
      membership = household.household_memberships.find_by(user_id: user.id)
      paused = membership.nil? || membership.mia_personalization_paused?
      memories = if paused
        []
      else
        household.household_memories.visible_to(user).active.ordered.limit(MAX_MEMORIES).map do |memory|
          {
            id: memory.id,
            category: memory.category,
            value: bounded(memory.display_value),
            visibility: memory.visibility
          }
        end
      end

      {
        context_type: "user_curated_personalization",
        rule: "User-curated memory can shape wording, coaching style, and follow-up. It is never financial truth and must not override approved household, budget, debt, income, transaction, or document records.",
        paused: paused,
        memories: memories
      }
    end

    private

    attr_reader :household, :user

    def bounded(value)
      value.to_s.unicode_normalize(:nfkc).gsub(/[[:cntrl:]]/, " ").gsub(/[<>`]/, "").squish.truncate(HouseholdMemory::MAX_DISPLAY_LENGTH, omission: "…")
    end
  end
end
