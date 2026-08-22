Rails.application.config.after_initialize do
  PlaidIntegration::Configuration.validate! if ENV["PLAID_ENV"] == "production"
end
