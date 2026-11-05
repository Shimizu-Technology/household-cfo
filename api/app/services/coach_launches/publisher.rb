# frozen_string_literal: true

module CoachLaunches
  # Every existing publisher retains its gates and audit records. One outer
  # transaction prevents a disconnected browser from leaving a partial launch.
  class Publisher
    class Conflict < StandardError; end

    def initialize(persona:, actor:, review:, request_key:)
      @persona, @actor, @review, @request_key = persona, actor, review.deep_stringify_keys, request_key.to_s
      @workspace = persona.coach_workspace
    end

    def call!
      raise Conflict, "Reopen Go live to review this update." unless request_key.length.between?(1, 64)

      CoachLaunchReceipt.transaction(requires_new: true) do
        CoachWorkspaces::MutationAuthority.new(workspace:, actor:, permissions: :publish).call do |persisted_actor|
          @actor = persisted_actor
          policy = Mia::PersonaStudioPolicy.new(actor, workspace:)
          policy.publishable_personas.find(persona.id)
          digest = CohortReleases::Contract.digest(review)
          receipt = CoachLaunchReceipt.find_by(coach_workspace: workspace, user: actor, request_key:)
          if receipt
            raise Conflict, "This update changed. Review it again." unless receipt.request_digest == digest && receipt.coach_persona_id == persona.id

            raise Conflict, "This request was closed. Review the update before trying again." if receipt.result["status"] == "not_committed"

            next receipt.result
          end
          groups = Array(review.fetch("groups"))
          raise Conflict, "Choose at least one group." if groups.empty? || groups.size > 100 || groups.map { |g| g.fetch("id") }.uniq.size != groups.size

          cohorts = groups.sort_by { |group| group.fetch("id") }.map { |group| policy.assignment_manageable_cohorts.lock.find(group.fetch("id")) }
          cohorts.each { |cohort| CohortReleases::Authorization.new(cohort:, actor:).call! }
          persona.lock!
          check_persona!
          groups.each { |group| check_group!(cohorts.find { |c| c.id == group.fetch("id") }, group) }
          publish_settings!(cohorts)
          publish_voice!
          cohorts.each { |cohort| launch_group!(cohort, groups.find { |g| g.fetch("id") == cohort.id }) }
          result = { "groups" => cohorts.map { |c| { "id" => c.id, "name" => c.name, "challenge_closed" => challenge_closed?(c), "deferred_participants" => deferred_participants(c) } } }
          CoachLaunchReceipt.create!(coach_workspace: workspace, user: actor, coach_persona: persona, request_key:, request_digest: digest, result:)
          result
        end
      end
    end

    # Resolve an uncertain response without repeating a failing launch. The same
    # workspace lock waits for an in-flight commit. A negative result fences the
    # key, so a delayed original POST cannot launch after the coach starts over.
    def resolve!
      raise Conflict, "Reopen Go live to review this update." unless request_key.length.between?(1, 64)

      CoachWorkspaces::MutationAuthority.new(workspace:, actor:, permissions: :publish).call do |persisted_actor|
        policy = Mia::PersonaStudioPolicy.new(persisted_actor, workspace:)
        policy.publishable_personas.find(persona.id)
        digest = CohortReleases::Contract.digest(review)
        receipt = CoachLaunchReceipt.find_by(coach_workspace: workspace, user: persisted_actor, request_key:)
        if receipt && (receipt.request_digest != digest || receipt.coach_persona_id != persona.id)
          raise Conflict, "This request changed. Reopen its original program to check it."
        end
        receipt ||= CoachLaunchReceipt.create!(coach_workspace: workspace, user: persisted_actor, coach_persona: persona,
          request_key:, request_digest: digest, result: { "status" => "not_committed" })
        receipt.result["status"] == "not_committed" ? { status: "not_committed" } : { status: "live", launch: receipt.result }
      end
    end

    private

    attr_reader :persona, :actor, :review, :request_key, :workspace

    def check_persona!
      expected = review.fetch("persona")
      unless persona.draft_revision == expected.fetch("draft_revision") && persona.current_published_version_id == expected["published_version_id"]
        raise Conflict, "Your assistant changed. Preview again before going live."
      end
      actual = Mia::PersonaStudioSerializer.new(persona, policy: Mia::PersonaStudioPolicy.new(actor, workspace:)).detail
      raise Conflict, "Your assistant changed. Preview again." unless actual[:has_unpublished_changes] == expected["voice_changes"]
      return unless expected["voice_changes"]

      ready = Mia::PersonaRelease::Readiness.new(persona:, actor:).call.deep_stringify_keys
      %w[candidate evaluation_run behavioral_preview_evidence].each do |part|
        key = { "candidate" => "manifest_digest", "evaluation_run" => "run_digest", "behavioral_preview_evidence" => "digest" }.fetch(part)
        unless ready.dig(part, key).present? && ready.dig(part, key) == expected.fetch(part).fetch(key)
          raise Conflict, "Your voice or safety checks changed. Preview again before approving them."
        end
      end
      raise Conflict, "Your safety checks changed. Preview again." unless ready.dig("evaluation_run", "id") == expected.dig("evaluation_run", "id")
    end

    def check_group!(cohort, expected)
      unless cohort.status.in?(CohortRelease::USER_RELEASE_COHORT_STATUSES)
        raise Conflict, "#{cohort.name} is now read-only. Review your selected groups again."
      end
      current = CohortRollouts::StudioSerializer.new(cohort:, actor:).call
      candidate = CohortReleases::StudioSerializer.new(cohort:, actor:).call.dig(:readiness, :candidate)
      unless current.dig(:current_roster, :digest) == expected.fetch("roster_digest") &&
          current.dig(:active_release, :id) == expected["active_release_id"] && !current[:open_rollout] &&
          cohort.cohort_persona_assignment&.coach_persona_id == expected["assignment_persona_id"] &&
          candidate&.fetch(:bundle_digest) == expected.fetch("bundle_digest")
        raise Conflict, "#{cohort.name} changed. Review its latest settings and people before going live."
      end
    end

    def publish_settings!(cohorts)
      brand = workspace.workspace_brand_configuration
      publish_configuration!(brand, review.fetch("brand"), Branding::Publisher, idempotency_key: "#{request_key}:brand")
      tools = review.fetch("tools")
      raise Conflict, "Review the tools for every selected group." unless tools.map { |t| t.fetch("id") }.sort == cohorts.map(&:id).sort

      cohorts.each do |cohort|
        publish_configuration!(cohort.cohort_experience_configuration, tools.find { |t| t.fetch("id") == cohort.id }, CohortExperience::Publisher)
      end
    end

    def publish_configuration!(configuration, expected, publisher_class, **extra)
      configuration.lock!
      unless configuration.draft_revision == expected.fetch("draft_revision") && configuration.current_published_version_id == expected["published_version_id"] && configuration.preview_digest == expected.fetch("preview_digest")
        raise Conflict, "Your appearance or tools changed. Review the latest settings before going live."
      end
      # Never trust a browser's has_unpublished_changes flag.
      serializer = publisher_class == Branding::Publisher ? Branding::Serializer.new(configuration:, actor:) : CohortExperience::Serializer.new(configuration:, actor:)
      return if serializer.detail[:has_unpublished_changes] == false

      publisher_class.new(configuration:, actor:).publish!(expected_preview_digest: expected.fetch("preview_digest"), expected_draft_revision: expected.fetch("draft_revision"), expected_current_version_id: expected["published_version_id"], **extra)
    end

    def publish_voice!
      expected = review.fetch("persona")
      return unless expected["voice_changes"]

      ready = Mia::PersonaRelease::Readiness.new(persona:, actor:).call
      ready.fetch(:phrase_audience_reviews).each do |phrase|
        next if phrase[:review_state] == "approved"

        Mia::PersonaRelease::AudienceAttester.new(persona:, actor:).call!(candidate_digest: ready.dig(:candidate, :manifest_digest), artifact_id: phrase.fetch(:artifact_id), artifact_fingerprint: phrase.fetch(:artifact_fingerprint), decision: "approved")
      end
      run = CoachPersonaEvaluationRun.find(ready.dig(:evaluation_run, :id))
      Mia::PersonaRelease::RunApprover.new(run:, actor:).call!(decision: "approved", expected_run_digest: ready.dig(:evaluation_run, :run_digest)) unless ready.dig(:approval, :valid)
      ready = Mia::PersonaRelease::Readiness.new(persona:, actor:).call
      raise Conflict, "The voice or review changed. Preview again before publishing." unless ready[:ready]

      Mia::PersonaPublisher.new(persona:, actor:).publish!(
        expected_preview_digest: expected.fetch("preview_digest"), expected_draft_revision: expected.fetch("draft_revision"),
        expected_current_version_id: expected["published_version_id"], expected_release_candidate_digest: ready.dig(:candidate, :manifest_digest),
        expected_evaluation_run_digest: ready.dig(:evaluation_run, :run_digest), expected_evaluation_approval_digest: ready.dig(:approval, :approval_digest),
        expected_behavioral_preview_digest: ready.dig(:behavioral_preview_evidence, :digest)
      )
    end

    def launch_group!(cohort, expected)
      ids = Mia::PersonaAssignmentCompatibility.participant_ids_for(cohort:)
      Mia::PersonaAssignmentCompatibility.lock_participants!(user_ids: ids)
      assignment = cohort.cohort_persona_assignment || cohort.build_cohort_persona_assignment
      assignment.update!(coach_persona: persona, coach_persona_version: persona.current_published_version, assigned_by_user: actor)
      cohort.reload
      studio = CohortReleases::StudioSerializer.new(cohort:, actor:).call
      readiness = studio.fetch(:readiness)
      raise Conflict, readiness.fetch(:blockers).join(" ") unless readiness.fetch(:ready) && readiness.fetch(:blockers).empty?

      candidate = readiness.fetch(:candidate)
      release_id = candidate[:expected_latest_release_id]
      if studio.dig(:readiness, :seal_needed)
        input = {
          expected_bundle_digest: candidate[:bundle_digest], expected_assignment_id: candidate[:assignment_id],
          expected_persona_version_id: candidate[:coach_persona_version_id], expected_experience_version_id: candidate[:cohort_experience_version_id],
          expected_brand_version_id: candidate[:workspace_brand_version_id], expected_latest_release_id: release_id,
          expected_tool_registry_digest: candidate[:tool_registry_digest], expected_tool_registry_version: candidate[:tool_registry_version]
        }
        release_id = operation!(cohort, "cohort.release.seal", input, "seal:#{cohort.id}").release.id
      end
      raise Conflict, "#{cohort.name} needs a saved version before going live." unless release_id
      return if cohort.active_cohort_release_id == release_id

      if cohort.active_cohort_release_id.nil?
        launcher = CohortReleases::InitialLauncher.new(cohort:, actor:)
        preview = launcher.preview
        launcher.call!(release_id:, preview_digest: preview.fetch(:preview_digest), expected_roster_digest: expected.fetch("roster_digest"), request_key: "#{request_key}:launch:#{cohort.id}")
      else
        rollout = operation!(cohort, "cohort.rollout.plan", { target_release_id: release_id, expected_latest_release_id: release_id, expected_roster_digest: expected.fetch("roster_digest"), waves: [ { name: "Everyone reviewed", user_ids: expected.fetch("participant_ids") } ] }, "plan:#{cohort.id}").rollout
        # A planned transition proves the baseline against the currently locked
        # cohort. Check its complete execution evidence now, before completion
        # moves that pointer. Subsequent transitions still validate at COMMIT.
        constraints = "cohort_rollouts_integrity_deferred, cohort_rollout_transitions_integrity_deferred, coach_operation_rollout_integrity_deferred"
        connection = Cohort.connection
        connection.execute("SET CONSTRAINTS #{constraints} IMMEDIATE")
        connection.execute("SET CONSTRAINTS #{constraints} DEFERRED")
        2.times do |step|
          break if rollout.status == "completed"

          payload = CohortRollouts::StudioSerializer.new(cohort: cohort.reload, actor:).call_with_rollout(rollout).last
          rollout = operation!(cohort, "cohort.rollout.advance", { rollout_id: rollout.id, expected_status: payload[:status], expected_current_wave_position: payload[:current_wave_position], expected_latest_transition_id: payload[:latest_transition_id], readiness_digest: payload[:next_wave_readiness_digest] }, "advance:#{cohort.id}:#{step}").rollout
        end
        raise Conflict, "#{cohort.name} is waiting for participant readiness. Nothing went live." unless rollout.status == "completed"
      end
    end

    def operation!(cohort, key, input, suffix)
      operation = CoachOperations::Registry::OPERATIONS.fetch(key)
      CoachOperations::Runner.new(cohort:, actor:).call!(operation_key: key, operation_version: operation::VERSION, input:, request_key: "#{request_key}:#{suffix}")
    end

    def deferred_participants(cohort)
      CohortRollouts::Eligibility.new(cohort:).readiness_for_users(
        User.where(id: CohortRollouts::Contract.participant_user_ids(cohort))
      ).select { |entry| entry.fetch(:state).in?(%w[awaiting_acceptance revoked]) }
        .map { |entry| entry.stringify_keys.merge("reason" => "No active experience; latest release is available when access is accepted.") }
    end

    def challenge_closed?(cohort)
      cohort.cohort_experience_configuration.current_published_version.config["experience_mode"] == "savings_challenge" &&
        (!cohort.savings_challenge_enabled || cohort.savings_challenge_release_hold)
    end
  end
end
