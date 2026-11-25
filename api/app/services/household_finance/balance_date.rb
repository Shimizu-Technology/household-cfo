module HouseholdFinance
  # How Mia names the day a saved balance is from: "Oct 31", or "Oct 31, 2025"
  # outside the current year. A balance without a date gets no date.
  module BalanceDate
    module_function

    def label(date, today = Date.current)
      date.strftime(date.year == today.year ? "%b %-d" : "%b %-d, %Y")
    end

    # " Your account balances are as of Oct 31." when every liquid account has a
    # known, dated balance; otherwise nothing, so no date is implied.
    def liquid_sentence(household)
      accounts = household.accounts.active.select(&:liquid?)
      return "" if accounts.empty? || accounts.any? { |account| !account.balance_known? || account.balance_as_of_on.nil? }

      dates = accounts.map(&:balance_as_of_on).uniq.sort
      dates.one? ? " Your account balances are as of #{label(dates.first)}." : " Your account balances are as of #{label(dates.first)} or later."
    end
  end
end
