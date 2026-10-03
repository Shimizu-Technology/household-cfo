# frozen_string_literal: true

class CohortRelease < ApplicationRecord
  PUBLICATION_SOURCES = %w[user legacy_backfill system].freeze
  EVENT_TYPES = %w[release restore reconciliation].freeze
  PERSONA_MODES = %w[published_version neutral_builtin].freeze
  EXPERIENCE_MODES = %w[published_version safe_default].freeze
  BRAND_MODES = %w[published_version legacy_household_cfo_builtin].freeze
  LEGACY_RECONCILIATION_REQUEST_KEY = "legacy-backfill-v1"
  USER_RELEASE_COHORT_STATUSES = %w[draft enrolling active].freeze

  belongs_to :cohort
  belongs_to :coach_workspace
  belongs_to :released_by_user, class_name: "User", optional: true, inverse_of: :released_cohort_releases
  belongs_to :source_release, class_name: "CohortRelease", optional: true, inverse_of: :derived_releases
  belongs_to :coach_persona, optional: true
  belongs_to :coach_persona_version, optional: true
  belongs_to :cohort_experience_configuration
  belongs_to :cohort_experience_version, optional: true
  belongs_to :workspace_brand_version, optional: true

  has_many :derived_releases,
    class_name: "CohortRelease",
    foreign_key: :source_release_id,
    dependent: :restrict_with_exception,
    inverse_of: :source_release
  has_one :coach_operation_execution, dependent: :restrict_with_exception, inverse_of: :cohort_release
  has_many :targeted_cohort_rollouts, class_name: "CohortRollout", foreign_key: :target_cohort_release_id,
    dependent: :restrict_with_exception, inverse_of: :target_cohort_release
  has_many :rollback_cohort_rollouts, class_name: "CohortRollout", foreign_key: :rollback_cohort_release_id,
    dependent: :restrict_with_exception, inverse_of: :rollback_cohort_release
  has_many :rollback_cohort_rollout_transitions, class_name: "CohortRolloutTransition",
    foreign_key: :rollback_cohort_release_id, dependent: :restrict_with_exception,
    inverse_of: :rollback_cohort_release
  has_many :active_for_cohorts, class_name: "Cohort", foreign_key: :active_cohort_release_id,
    dependent: :restrict_with_exception, inverse_of: :active_cohort_release
  has_many :baseline_cohort_rollouts, class_name: "CohortRollout", foreign_key: :baseline_cohort_release_id,
    dependent: :restrict_with_exception, inverse_of: :baseline_cohort_release
  has_many :cohort_release_exposures, dependent: :restrict_with_exception
  has_many :activation_events_from, class_name: "CohortReleaseActivationEvent",
    foreign_key: :from_cohort_release_id, dependent: :restrict_with_exception
  has_many :activation_events_to, class_name: "CohortReleaseActivationEvent",
    foreign_key: :to_cohort_release_id, dependent: :restrict_with_exception

  validates :release_number, numericality: { only_integer: true, greater_than: 0 },
    uniqueness: { scope: :cohort_id }
  validates :publication_source, inclusion: { in: PUBLICATION_SOURCES }
  validates :event_type, inclusion: { in: EVENT_TYPES }
  validates :persona_mode, inclusion: { in: PERSONA_MODES }
  validates :experience_mode, inclusion: { in: EXPERIENCE_MODES }
  validates :tool_registry_version, numericality: { only_integer: true, greater_than: 0 }
  validates :manifest_schema, inclusion: { in: CohortReleases::Contract::SUPPORTED_SCHEMAS }
  validates :request_key, presence: true, length: { maximum: 100 }, uniqueness: { scope: :cohort_id }
  validates :persona_snapshot_digest, :experience_snapshot_digest, :tool_registry_digest,
    :bundle_digest, :manifest_digest, :request_fingerprint, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :brand_snapshot_digest, format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true
  validate :workspace_and_component_boundaries
  validate :source_and_actor_shape
  validate :reserved_request_key_scope
  validate :user_actor_authority, on: :create
  validate :snapshot_and_manifest_integrity
  validate :canonical_release_source, on: :create
  validate :new_release_uses_current_schema, on: :create
  validate :sealed_record_is_immutable, on: :update

  before_destroy :prevent_destroy

  def integrity_report
    CohortReleases::Integrity.new(self).call
  end

  def integrity_valid?
    integrity_report.fetch(:valid)
  end

  private

  def workspace_and_component_boundaries
    errors.add(:coach_workspace, "must match the cohort") if cohort && coach_workspace_id != cohort.coach_workspace_id

    if persona_mode == "published_version"
      errors.add(:coach_persona, "is required for a published persona release") unless coach_persona
      errors.add(:coach_persona_version, "is required for a published persona release") unless coach_persona_version
      if coach_persona && coach_persona.coach_workspace_id != coach_workspace_id
        errors.add(:coach_persona, "must belong to the release workspace")
      end
      if coach_persona_version && coach_persona_version.coach_persona_id != coach_persona_id
        errors.add(:coach_persona_version, "must belong to the release persona")
      end
    elsif coach_persona_id || coach_persona_version_id
      errors.add(:persona_mode, "neutral releases cannot reference a coach persona")
    end

    if cohort_experience_configuration && cohort_experience_configuration.cohort_id != cohort_id
      errors.add(:cohort_experience_configuration, "must belong to the release cohort")
    end
    if cohort_experience_version &&
        cohort_experience_version.cohort_experience_configuration_id != cohort_experience_configuration_id
      errors.add(:cohort_experience_version, "must belong to the release experience configuration")
    end

    validate_brand_boundary
  end

  def source_and_actor_shape
    if publication_source == "user"
      errors.add(:released_by_user, "is required for a user release") unless released_by_user
      errors.add(:actor_role_snapshot, "must record release authority") unless actor_role_snapshot.in?(%w[platform_admin owner reviewer])
    elsif released_by_user || actor_role_snapshot
      errors.add(:released_by_user, "and role must be blank for system-created release evidence")
    end

    if event_type == "restore"
      errors.add(:source_release, "is required for a restore") unless source_release
      if source_release && source_release.cohort_id != cohort_id
        errors.add(:source_release, "must belong to the same cohort")
      end
    elsif source_release
      errors.add(:source_release, "is only allowed for a restore")
    end
  end

  def user_actor_authority
    return unless publication_source == "user" && cohort_id && released_by_user

    locked_cohort = Cohort.lock.find(cohort_id)
    authorized_actor, authorized_role = CohortReleases::Authorization.new(
      cohort: locked_cohort,
      actor: released_by_user
    ).call!
    unless locked_cohort.status.in?(USER_RELEASE_COHORT_STATUSES)
      errors.add(:cohort, "must be open for a user release")
    end
    return if authorized_actor.id == released_by_user_id && authorized_role == actor_role_snapshot

    errors.add(:released_by_user, "authority must match the recorded release role")
  rescue CohortReleases::Authorization::NotAuthorized, ActiveRecord::RecordNotFound
    errors.add(:released_by_user, "must currently have release authority for this workspace")
  end

  def reserved_request_key_scope
    return unless request_key == LEGACY_RECONCILIATION_REQUEST_KEY
    return if publication_source == "legacy_backfill" && event_type == "reconciliation"

    errors.add(:request_key, "is reserved for legacy reconciliation")
  end

  def snapshot_and_manifest_integrity
    report = integrity_report
    report.fetch(:errors).each { |message| errors.add(:base, message) }
    if new_record? && !report.fetch(:runtime_compatible)
      errors.add(:base, "cohort release snapshots must match the current sealed runtime contract")
    end
  end

  def canonical_release_source
    return unless cohort

    if event_type == "restore"
      validate_restore_source
    else
      validate_current_candidate
    end
  rescue StandardError => error
    errors.add(:base, "cohort release source could not be verified (#{error.class})")
  end

  def validate_current_candidate
    candidate = CohortReleases::CandidateBuilder.new(
      cohort: cohort,
      strict: publication_source == "user"
    ).call
    errors.add(:base, "cohort release source is incomplete: #{candidate.blockers.join(' ')}") if candidate.blockers.any?
    return if candidate_matches?(candidate)

    errors.add(:base, "cohort release must match the cohort's current canonical configuration")
  end

  def validate_restore_source
    unless source_release && source_matches?
      errors.add(:base, "restored cohort release must exactly match its immutable source")
    end
    return unless publication_source == "user" && source_release && cohort

    CohortReleases::RestoreGovernance.new(cohort: cohort, source_release: source_release).call.each do |message|
      errors.add(:base, message)
    end
  end

  def candidate_matches?(candidate)
    coach_persona_id == candidate.persona&.id &&
      coach_persona_version_id == candidate.persona_version&.id &&
      cohort_experience_configuration_id == candidate.experience_configuration&.id &&
      cohort_experience_version_id == candidate.experience_version&.id &&
      persona_mode == candidate.persona_snapshot["mode"] &&
      experience_mode == candidate.experience_snapshot["mode"] &&
      persona_snapshot == candidate.persona_snapshot &&
      experience_snapshot == candidate.experience_snapshot &&
      workspace_brand_version_id == candidate.brand_version&.id &&
      brand_mode == candidate.brand_snapshot["mode"] &&
      brand_snapshot == candidate.brand_snapshot &&
      tool_registry_snapshot == candidate.tool_registry_snapshot &&
      bundle == candidate.bundle && bundle_digest == candidate.bundle_digest
  end

  def source_matches?
    candidate = CohortReleases::RestoreCandidateBuilder.new(
      cohort: cohort,
      source_release: source_release
    ).call
    candidate_matches?(candidate)
  end

  def validate_brand_boundary
    if manifest_schema == CohortReleases::Contract::V1_SCHEMA
      if brand_mode || workspace_brand_version_id || brand_snapshot || brand_snapshot_digest
        errors.add(:brand_mode, "must be blank for a v1 release")
      end
      return
    end

    errors.add(:brand_mode, "is invalid") unless brand_mode.in?(BRAND_MODES)
    if brand_mode == "published_version"
      errors.add(:workspace_brand_version, "is required for a published brand") unless workspace_brand_version
      if workspace_brand_version && workspace_brand_version.coach_workspace_id != coach_workspace_id
        errors.add(:workspace_brand_version, "must belong to the release workspace")
      end
    elsif workspace_brand_version_id
      errors.add(:brand_mode, "built-in branding cannot reference a workspace brand version")
    end
    errors.add(:brand_snapshot, "is required for a v2 release") unless brand_snapshot.is_a?(Hash)
  end

  def new_release_uses_current_schema
    return if manifest_schema == CohortReleases::Contract::CURRENT_SCHEMA

    errors.add(:manifest_schema, "must use the current schema for new releases")
  end

  def sealed_record_is_immutable
    errors.add(:base, "cohort releases are immutable") if has_changes_to_save?
  end

  def prevent_destroy
    errors.add(:base, "cohort releases cannot be deleted")
    throw :abort
  end
end
