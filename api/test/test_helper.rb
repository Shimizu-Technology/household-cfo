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
      ].each { |key| ENV.delete(key) }
    end
  end
end
