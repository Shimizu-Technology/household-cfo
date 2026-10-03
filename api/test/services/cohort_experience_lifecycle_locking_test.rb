# frozen_string_literal: true

require "test_helper"
require "timeout"

class CohortExperienceLifecycleLockingTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "publish rechecks cohort editability after a concurrent completion lock" do
    suffix = SecureRandom.hex(6)
    admin = User.create!(
      clerk_id: "experience_lock_admin_#{suffix}",
      email: "experience-lock-#{suffix}@example.com",
      role: "admin",
      invitation_status: "accepted"
    )
    cohort = Cohort.create!(name: "Experience lock #{suffix}", status: "active", created_by_user: admin)
    configuration = cohort.cohort_experience_configuration
    publisher = CohortExperience::Publisher.new(configuration: configuration, actor: admin)
    digest = publisher.preview!(expected_draft_revision: configuration.draft_revision)
    draft_revision = configuration.reload.draft_revision

    cohort_locked = Queue.new
    allow_completion = Queue.new
    mutation_started = Queue.new
    mutation_result = Queue.new

    completion_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Cohort.transaction do
          locked_cohort = Cohort.lock.find(cohort.id)
          cohort_locked << true
          allow_completion.pop
          locked_cohort.update!(status: "completed")
        end
      end
    end
    Timeout.timeout(3) { cohort_locked.pop }

    mutation_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        local_configuration = CohortExperienceConfiguration.find(configuration.id)
        mutation_started << true
        result = begin
          CohortExperience::Publisher.new(configuration: local_configuration, actor: User.find(admin.id)).publish!(
            expected_preview_digest: digest,
            expected_draft_revision: draft_revision,
            expected_current_version_id: nil
          )
        rescue StandardError => error
          error
        end
        mutation_result << result
      end
    end
    Timeout.timeout(3) { mutation_started.pop }
    allow_completion << true
    completion_thread.join(3)
    mutation_thread.join(3)

    assert_not completion_thread.alive?, "cohort completion did not finish"
    assert_not mutation_thread.alive?, "participant-tools publish did not finish"
    assert_instance_of CohortExperience::Publisher::ReadOnlyError, Timeout.timeout(3) { mutation_result.pop }
    assert_empty configuration.versions.reload
    assert_equal "completed", cohort.reload.status
  ensure
    allow_completion << true if defined?(allow_completion)
    completion_thread&.join(1)
    mutation_thread&.join(1)
    CohortExperienceConfiguration.where(id: configuration&.id).update_all(current_published_version_id: nil)
    CohortExperiencePublicationEvent.where(cohort_experience_configuration_id: configuration&.id).delete_all
    CohortExperienceVersion.where(cohort_experience_configuration_id: configuration&.id).delete_all
    CohortExperienceConfiguration.where(id: configuration&.id).delete_all
    Cohort.where(id: cohort&.id).delete_all
    delete_empty_coach_workspaces_for_users(admin&.id)
    User.where(id: admin&.id).delete_all
  end
end
