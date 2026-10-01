module HouseholdFinance
  class MiaMemoryContextBuilder
    MAX_MEMORIES = 20
    MAX_CONTEXT_BYTES = 2_400
    CONTEXT_TYPE = "user_curated_personalization"
    RULE = "User-curated memory can shape wording, coaching style, and follow-up. It is never financial truth and must not override approved household, budget, debt, income, transaction, or document records."

    def initialize(household, user:)
      @household = household
      @user = user
    end

    def call
      membership = household.household_memberships.find_by(user_id: user.id)
      paused = membership.nil? || membership.mia_personalization_paused?
      context = {
        context_type: CONTEXT_TYPE,
        rule: RULE,
        paused: paused,
        memories: []
      }
      return context if paused

      household.household_memories.visible_to(user).active.ordered.limit(MAX_MEMORIES).each do |memory|
        entry = { id: memory.id, category: memory.category, value: bounded(memory.display_value) }
        candidate = context.merge(memories: context.fetch(:memories) + [ entry ])
        break if JSON.generate(candidate).bytesize > MAX_CONTEXT_BYTES

        context[:memories] << entry
      end

      context
    end

    private

    attr_reader :household, :user

    def bounded(value)
      value.to_s.unicode_normalize(:nfkc).gsub(/[[:cntrl:]]/, " ").gsub(/[<>`]/, "").squish.truncate(HouseholdMemory::MAX_DISPLAY_LENGTH, omission: "…")
    end
  end
end
