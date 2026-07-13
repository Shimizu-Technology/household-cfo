module PlaidIntegration
  class LinkToken
    def initialize(household:, user:, plaid_item: nil)
      @household = household
      @user = user
      @plaid_item = plaid_item
    end

    def call
      Client.safely do |client|
        attributes = {
          user: Plaid::LinkTokenCreateRequestUser.new(client_user_id: "household-#{household.id}-user-#{user.id}"),
          client_name: "Household CFO Method",
          country_codes: [ Plaid::CountryCode::US ],
          language: "en",
          access_token: plaid_item&.access_token,
          webhook: Configuration.webhook_url
        }
        unless plaid_item
          attributes[:products] = [ Plaid::Products::TRANSACTIONS ]
          attributes[:transactions] = Plaid::LinkTokenTransactions.new(days_requested: 730)
        end
        request = Plaid::LinkTokenCreateRequest.new(**attributes)
        client.link_token_create(request).link_token
      end
    end

    private

    attr_reader :household, :user, :plaid_item
  end
end
