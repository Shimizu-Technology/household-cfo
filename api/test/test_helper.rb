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
      # Local api/.env may configure Clerk/OpenRouter for manual testing. Keep
      # automated tests opt-in so demo tests validate no-Clerk/no-network preview mode.
      %w[
        CLERK_JWKS_URL
        CLERK_ISSUER
        CLERK_AUDIENCE
        CLERK_AUDIENCES
        CLERK_SECRET_KEY
        CLERK_BOOTSTRAP_ADMIN_EMAILS
        ALLOW_FIRST_USER_BOOTSTRAP
        OPENROUTER_API_KEY
        OPENROUTER_EXTRACTION_MODEL
        OPENROUTER_PDF_ENGINE
        OPENROUTER_TRANSCRIPTION_MODEL
        MIA_TRANSCRIPTION_LANGUAGE
        MIA_TRANSCRIPTION_MODEL
        OPENROUTER_MIA_INTENT_MODEL
        OPENROUTER_MIA_URL
        MIA_PROVIDER_MAX_CONCURRENCY
        AWS_REGION
        AWS_ACCESS_KEY_ID
        AWS_SECRET_ACCESS_KEY
        AWS_S3_BUCKET
        AWS_S3_PREFIX
        MIA_PERSONA_ID
        RESEND_API_KEY
        RESEND_FROM_EMAIL
        MAILER_FROM_EMAIL
        PLAID_ENV
        PLAID_CLIENT_ID
        PLAID_SECRET
        PLAID_DATA_ENCRYPTION_KEY
        PLAID_WEBHOOK_URL
        PLAID_REDIRECT_URI
        PLAID_LINK_CUSTOMIZATION_NAME
      ].each { |key| ENV.delete(key) }
    end

    private

    def with_mia_provider_capacity_rejected
      singleton = HouseholdFinance::MiaProviderAdmission.singleton_class
      original = singleton.instance_method(:with_slot)
      singleton.define_method(:with_slot) { |**_options, &_block| nil }
      yield
    ensure
      singleton.send(:remove_method, :with_slot) if singleton.method_defined?(:with_slot)
      singleton.define_method(:with_slot, original)
    end
  end
end
