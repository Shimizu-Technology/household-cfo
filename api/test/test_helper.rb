ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    setup do
      # Local api/.env may configure Clerk for manual testing. Keep automated tests
      # opt-in so demo endpoint tests still validate no-Clerk preview mode.
      %w[
        CLERK_JWKS_URL
        CLERK_ISSUER
        CLERK_AUDIENCE
        CLERK_AUDIENCES
        CLERK_SECRET_KEY
        CLERK_BOOTSTRAP_ADMIN_EMAILS
        ALLOW_FIRST_USER_BOOTSTRAP
      ].each { |key| ENV.delete(key) }
    end
  end
end
