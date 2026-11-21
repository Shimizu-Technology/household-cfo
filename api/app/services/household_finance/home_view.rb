# frozen_string_literal: true

module HouseholdFinance
  # What Home leads with. The program's method sets the default (month first); a person's
  # own saved choice wins for that person.
  module HomeView
    module_function

    def payload(method, membership:)
      program = method.fetch("home_view")
      chosen = membership&.home_view
      { program: program, chosen: chosen, effective: chosen || program }
    end
  end
end
