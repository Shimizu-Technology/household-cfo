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
        AUTH_PROVIDER
        AUTH_PUBLIC_PROVIDER
        WORKOS_CLIENT_ID
        WORKOS_API_KEY
        WORKOS_ISSUER
        WORKOS_API_HOSTNAME
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
        MIA_PROVIDER_ADMISSION_WAIT_MS
        AWS_REGION
        AWS_ACCESS_KEY_ID
        AWS_SECRET_ACCESS_KEY
        AWS_S3_BUCKET
        AWS_S3_PREFIX
        CONTENT_SOURCE_URL_ENCRYPTION_KEY_V1
        CONTENT_SOURCE_URL_HMAC_KEY_V1
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

    def delete_workspace_membership_events(workspace_ids)
      ids = Array(workspace_ids).compact
      return if ids.empty?

      connection = ActiveRecord::Base.connection
      connection.execute("ALTER TABLE coach_workspace_membership_events DISABLE TRIGGER workspace_membership_events_immutable")
      CoachWorkspaceMembershipEvent.where(coach_workspace_id: ids).delete_all
    ensure
      connection&.execute("ALTER TABLE coach_workspace_membership_events ENABLE TRIGGER workspace_membership_events_immutable")
    end

    def delete_workspace_brand_records(workspace_ids)
      ids = Array(workspace_ids).compact
      return if ids.empty? || !WorkspaceBrandConfiguration.table_exists?

      triggers = {
        "workspace_brand_versions" => "workspace_brand_versions_immutable",
        "workspace_brand_publication_events" => "workspace_brand_publication_events_immutable",
        "coach_workspace_domain_events" => "coach_workspace_domain_events_immutable"
      }
      triggers.each { |table, trigger| ActiveRecord::Base.connection.execute("ALTER TABLE #{table} DISABLE TRIGGER #{trigger}") }

      configuration_ids = WorkspaceBrandConfiguration.where(coach_workspace_id: ids).pluck(:id)
      domain_ids = CoachWorkspaceDomain.where(coach_workspace_id: ids).pluck(:id)
      CoachWorkspaceDomainEvent.where(coach_workspace_domain_id: domain_ids).delete_all
      CoachWorkspaceDomain.where(id: domain_ids).delete_all
      WorkspaceBrandPublicationEvent.where(workspace_brand_configuration_id: configuration_ids).delete_all
      WorkspaceBrandConfiguration.where(id: configuration_ids).update_all(current_published_version_id: nil)
      WorkspaceBrandVersion.where(workspace_brand_configuration_id: configuration_ids).delete_all
      WorkspaceBrandConfiguration.where(id: configuration_ids).delete_all
    ensure
      triggers&.each { |table, trigger| ActiveRecord::Base.connection.execute("ALTER TABLE #{table} ENABLE TRIGGER #{trigger}") }
    end

    def delete_empty_coach_workspaces_for_users(user_ids)
      workspace_ids = CoachWorkspace.where(created_by_user_id: Array(user_ids).compact).pluck(:id)
      return if workspace_ids.empty?

      CoachProfile.where(coach_workspace_id: workspace_ids).delete_all
      CoachWorkspaceMembership.where(coach_workspace_id: workspace_ids).delete_all
      delete_workspace_membership_events(workspace_ids)
      delete_workspace_brand_records(workspace_ids)
      CoachWorkspace.where(id: workspace_ids).delete_all
    end
  end
end
