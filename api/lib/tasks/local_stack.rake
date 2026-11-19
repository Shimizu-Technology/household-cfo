namespace :local_stack do
  desc "Seed the local full stack with fictional sign-ins (bin/local-stack runs this)"
  task seed: :environment do
    abort "local_stack:seed runs only inside bin/local-stack (HCFO_LOCAL_STACK=1)." unless ENV["HCFO_LOCAL_STACK"] == "1"

    # The web app's local sign-in (?pilot_e2e_role=…&pilot_e2e_live_api=true)
    # presents these emails; a pending invitation links on first sign-in.
    people = [
      { email: "admin@pilot.test", role: "admin", first_name: "Pilot", last_name: "Admin" },
      { email: "coach@pilot.test", role: "coach", first_name: "Coach", last_name: "Mendiola" },
      { email: "participant@pilot.test", role: "participant", first_name: "Test", last_name: "Participant" }
    ]
    people.each do |person|
      user = User.find_or_initialize_by(email: person[:email])
      if user.new_record?
        user.assign_attributes(person.merge(clerk_id: "pending_#{SecureRandom.uuid}", invitation_status: "pending", invited_at: Time.current))
        user.save!
        puts "Seeded #{person[:role]} #{person[:email]}"
      else
        puts "Kept #{user.role} #{user.email} (#{user.invitation_status})"
      end
    end
  end

  desc "Give the fictional participant a set-up household plan (bin/local-stack run bin/rails local_stack:household)"
  task household: :environment do
    abort "local_stack:household runs only inside bin/local-stack (HCFO_LOCAL_STACK=1)." unless ENV["HCFO_LOCAL_STACK"] == "1"

    user = User.find_by!(email: "participant@pilot.test")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    abort "The participant's household already has a plan; run bin/local-stack reset first." if household.income_sources.exists?

    # Fictional numbers in the shape of the Talun test family, never a real household.
    HouseholdFinance::SetupUpdater.new(household, household_name: "Talun household", primary_goal: "Keep the bills covered and build a 3-month cushion",
      primary_income: "5400", fixed_expenses: "2600", flexible_spend: "1300", expected_sinking_fund: "250", unexpected_sinking_fund: "150",
      emergency_fund: "3200", target_runway_months: "3", credit_card_debt: "1800", debt_payment: "90").call
    puts "Set up #{household.reload.name} for participant@pilot.test"
  end
end
