# frozen_string_literal: true

module CohortReleases
  class InitialLauncher
    Result = Data.define(:event, :replayed)
    class Conflict < StandardError; end
    class Invalid < StandardError; end
    class Incomplete < StandardError
      attr_reader :blockers

      def initialize(blockers)
        @blockers = blockers
        super(blockers.join(" "))
      end
    end

    def initialize(cohort:, actor:)
      @cohort = cohort
      @actor = actor
    end

    def preview
      candidate = CandidateBuilder.new(cohort: cohort, strict: true).call
      release = cohort.cohort_releases.order(release_number: :desc).first
      blockers = candidate.blockers.dup
      blockers << "Seal a release before launching this cohort." unless release
      blockers << "This cohort is already launched. Use a rollout for later changes." if cohort.active_cohort_release_id
      blockers << "Completed and archived cohorts are read-only." unless cohort.status.in?(CohortRelease::USER_RELEASE_COHORT_STATUSES)
      blockers << "Finish or cancel the open rollout before launching this cohort." if cohort.cohort_rollouts.where(status: CohortRollout::OPEN_STATUSES).exists?
      if release
        integrity = release.integrity_report
        blockers << "The sealed release failed its integrity or runtime compatibility checks." unless integrity.fetch(:valid) && integrity.fetch(:runtime_compatible)
        blockers << "The published settings changed. Seal their new release before launching." unless SemanticParity.new(candidate: candidate, release: release).equivalent?
      end
      members = cohort.cohort_memberships.where(role: "participant").order(:id).pluck(:id, :user_id, :created_at)
      digest = Contract.digest(
        "schema" => "cohort_initial_launch_preview_v1", "cohort_id" => cohort.id,
        "status" => cohort.status, "active_release_id" => cohort.active_cohort_release_id,
        "release_id" => release&.id, "release_bundle_digest" => release&.bundle_digest,
        "candidate_bundle_digest" => candidate.bundle_digest,
        "memberships" => members.map { |id, user_id, started_at| [ id, user_id, started_at.iso8601(6) ] }
      )
      membership = cohort.coach_workspace.membership_for(actor)
      permissions = CoachWorkspace::PERMISSIONS.fetch(membership&.role, [])
      authorized = actor&.admin? || (permissions.include?(:publish) && permissions.include?(:assign))
      {
        cohort: { id: cohort.id, name: cohort.name, participant_count: members.length },
        active_release_id: cohort.active_cohort_release_id,
        release: release && { id: release.id, release_number: release.release_number },
        can_launch: !!authorized && blockers.empty?, blockers: blockers.uniq,
        preview_digest: digest,
        message: "Launching makes this sealed brand, assistant, and tools the default for every participant in this cohort. Later changes use a controlled rollout."
      }
    end

    def call!(release_id:, preview_digest:, request_key:)
      key = request_key.to_s.strip
      raise Invalid, "Idempotency-Key must be between 1 and 100 characters" unless key.length.between?(1, 100)
      id = Integer(release_id.to_s, exception: false)
      raise Invalid, "Select a sealed release and reload its launch review." unless id&.positive? && preview_digest.to_s.match?(/\A[0-9a-f]{64}\z/)

      cohort.with_lock do
        locked_actor, actor_role = Authorization.new(cohort: cohort, actor: actor).call!
        fingerprint = Contract.digest(
          "schema" => "cohort_initial_launch_request_v1", "release_id" => id,
          "cohort_id" => cohort.id, "preview_digest" => preview_digest,
          "actor_user_id" => locked_actor.id, "actor_role_snapshot" => actor_role, "request_key" => key
        )
        existing = cohort.cohort_release_activation_events.find_by(request_key: key)
        if existing
          unless existing.event_type == "initial_launch" && existing.request_fingerprint == fingerprint
            raise Conflict, "This request key was already used for a different activation. Reload before trying again."
          end
          return Result.new(event: existing, replayed: true)
        end

        lock_components!
        review = preview
        unless review.fetch(:release)&.fetch(:id) == id && review.fetch(:preview_digest) == preview_digest
          raise Conflict, "The release, participants, or published settings changed. Reload and review the launch again."
        end
        raise Incomplete, review.fetch(:blockers) unless review.fetch(:blockers).empty?

        event = cohort.cohort_release_activation_events.create!(
          coach_workspace: cohort.coach_workspace, to_cohort_release_id: id,
          event_type: "initial_launch", actor_user: locked_actor, actor_role_snapshot: actor_role,
          request_key: key, request_fingerprint: fingerprint, occurred_at: Time.current
        )
        cohort.update!(active_cohort_release_id: id)
        Result.new(event: event, replayed: false)
      end
    end

    private

    attr_reader :cohort, :actor

    def lock_components!
      assignment = cohort.cohort_persona_assignment
      CoachPersona.lock.find(assignment.coach_persona_id) if assignment
      cohort.association(:cohort_persona_assignment).reset
      CohortExperienceConfiguration.lock.find_by(cohort_id: cohort.id)
      cohort.association(:cohort_experience_configuration).reset
      WorkspaceBrandConfiguration.lock.find_by(coach_workspace_id: cohort.coach_workspace_id)
      cohort.coach_workspace.association(:workspace_brand_configuration).reset
    end
  end
end
