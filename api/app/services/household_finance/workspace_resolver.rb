module HouseholdFinance
  class WorkspaceResolver
    def initialize(user)
      @user = user
    end

    # The user row lock only serializes first-time creation. Resolving an
    # existing household takes no lock: callers often resolve inside a
    # transaction that then locks the household and, later, the user. Taking
    # the user first there inverted that order and deadlocked parallel reads.
    def household
      existing_household || user.with_lock do
        existing_household || create_household
      end
    rescue ActiveRecord::RecordNotUnique
      existing_household || raise
    end

    private

    attr_reader :user

    def existing_household
      user.households.order("household_memberships.created_at ASC").first
    end

    def create_household
      household = Household.create!(
        created_by_user: user,
        name: default_household_name,
        location: "Guam",
        stage: "First cohort",
        primary_goal: "Build a clear monthly money rhythm."
      )
      household.household_memberships.create!(user: user, role: "owner")
      household
    end

    def default_household_name
      name = user.full_name.to_s.strip
      return "My Household" if name.blank?

      "#{name}'s Household"
    end
  end
end
