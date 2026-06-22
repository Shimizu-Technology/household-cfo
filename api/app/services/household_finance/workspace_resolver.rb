module HouseholdFinance
  class WorkspaceResolver
    def initialize(user)
      @user = user
    end

    def household
      user.with_lock do
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
