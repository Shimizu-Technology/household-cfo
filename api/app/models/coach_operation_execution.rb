# frozen_string_literal: true

class CoachOperationExecution < ApplicationRecord
  OPERATION_KEYS = %w[cohort.release.seal cohort.release.restore].freeze
  ACTOR_ROLES = %w[platform_admin owner reviewer].freeze

  belongs_to :coach_workspace
  belongs_to :cohort
  belongs_to :actor_user, class_name: "User", inverse_of: :coach_operation_executions
  belongs_to :cohort_release, inverse_of: :coach_operation_execution

  validates :operation_key, inclusion: { in: OPERATION_KEYS }
  validates :operation_version, inclusion: { in: [ 1 ] }
  validates :actor_role_snapshot, inclusion: { in: ACTOR_ROLES }
  validates :source, inclusion: { in: [ "api" ] }
  validates :request_key, presence: true, length: { maximum: 100 }, uniqueness: { scope: :cohort_id }
  validates :invocation_fingerprint, :request_fingerprint, :normalized_input_digest,
    :before_snapshot_digest, :predicted_after_snapshot_digest, :after_snapshot_digest,
    format: { with: /\A[0-9a-f]{64}\z/ }
  validates :completed_at, presence: true
  validates :cohort_release_id, uniqueness: true
  validate :json_values_are_objects
  validate :workspace_boundaries
  validate :snapshot_integrity
  validate :release_evidence_matches_execution, on: :create
  validate :sealed_record_is_immutable, on: :update

  before_destroy :prevent_destroy

  private

  def json_values_are_objects
    %i[normalized_input before_snapshot predicted_after_snapshot after_snapshot].each do |attribute|
      errors.add(attribute, "must be a JSON object") unless public_send(attribute).is_a?(Hash)
    end
  end

  def workspace_boundaries
    errors.add(:coach_workspace, "must match the cohort") if cohort && cohort.coach_workspace_id != coach_workspace_id
    return unless cohort_release && cohort

    if cohort_release.cohort_id != cohort_id || cohort_release.coach_workspace_id != coach_workspace_id
      errors.add(:cohort_release, "must belong to the operation cohort and workspace")
    end
  end

  def snapshot_integrity
    [
      [ :normalized_input_digest, normalized_input, normalized_input_digest ],
      [ :before_snapshot_digest, before_snapshot, before_snapshot_digest ],
      [ :predicted_after_snapshot_digest, predicted_after_snapshot, predicted_after_snapshot_digest ],
      [ :after_snapshot_digest, after_snapshot, after_snapshot_digest ]
    ].each do |attribute, payload, digest|
      errors.add(attribute, "does not match the canonical evidence") unless secure_match?(
        CoachOperations::Contract.digest(payload), digest
      )
    end

    expected_invocation = CoachOperations::Contract.invocation_fingerprint(
      cohort_id: cohort_id,
      coach_workspace_id: coach_workspace_id,
      actor_user_id: actor_user_id,
      actor_role_snapshot: actor_role_snapshot,
      operation_key: operation_key,
      operation_version: operation_version,
      normalized_input: normalized_input
    )
    errors.add(:invocation_fingerprint, "does not match the canonical invocation") unless secure_match?(
      expected_invocation, invocation_fingerprint
    )
    expected_request = CoachOperations::Contract.request_fingerprint(
      request_key: request_key,
      invocation_fingerprint: invocation_fingerprint
    )
    errors.add(:request_fingerprint, "does not match the canonical request") unless secure_match?(
      expected_request, request_fingerprint
    )
  end

  def release_evidence_matches_execution
    return unless cohort_release

    errors.add(:request_key, "must match the linked release") unless request_key == cohort_release.request_key
    errors.add(:actor_user, "must match the linked release") unless actor_user_id == cohort_release.released_by_user_id
    unless actor_role_snapshot == cohort_release.actor_role_snapshot
      errors.add(:actor_role_snapshot, "must match the linked release")
    end
    errors.add(:completed_at, "must match the linked release") unless completed_at == cohort_release.released_at
    unless cohort.cohort_releases.count == cohort_release.release_number
      errors.add(:cohort_release, "must be the latest contiguous release")
    end
    if cohort_release.release_number > 1 && previous_release.nil?
      errors.add(:cohort_release, "must have the preceding release evidence")
    end

    expected_event_type = {
      "cohort.release.seal" => "release",
      "cohort.release.restore" => "restore"
    }[operation_key]
    errors.add(:operation_key, "does not match the linked release event") unless cohort_release.event_type == expected_event_type

    if operation_key == "cohort.release.seal"
      validate_seal_input
    elsif operation_key == "cohort.release.restore"
      validate_restore_input
    end
    validate_before_and_prediction
    validate_after_snapshot
  end

  def validate_seal_input
    expected = {
      "expected_bundle_digest" => cohort_release.bundle_digest,
      "expected_persona_version_id" => cohort_release.coach_persona_version_id,
      "expected_experience_version_id" => cohort_release.cohort_experience_version_id,
      "expected_assignment_id" => cohort.cohort_persona_assignment&.id,
      "expected_latest_release_id" => previous_release&.id,
      "expected_tool_registry_digest" => cohort_release.tool_registry_digest,
      "expected_tool_registry_version" => cohort_release.tool_registry_version
    }
    errors.add(:normalized_input, "does not match the sealed release") unless normalized_input == expected
  end

  def validate_restore_input
    expected = {
      "expected_latest_release_id" => previous_release&.id,
      "source_bundle_digest" => cohort_release.bundle_digest,
      "source_experience_version_id" => cohort_release.cohort_experience_version_id,
      "source_persona_version_id" => cohort_release.coach_persona_version_id,
      "source_release_id" => cohort_release.source_release_id
    }
    errors.add(:normalized_input, "does not match the restored release") unless normalized_input == expected
  end

  def validate_after_snapshot
    expected = {
      "schema" => "cohort_release_state_v1",
      "cohort_id" => cohort_id,
      "coach_workspace_id" => coach_workspace_id,
      "release_count" => cohort_release.release_number,
      "latest_release_id" => cohort_release_id,
      "latest_release_number" => cohort_release.release_number,
      "latest_bundle_digest" => cohort_release.bundle_digest,
      "participant_runtime_changed" => false
    }
    errors.add(:after_snapshot, "does not match the linked release") unless after_snapshot == expected
  end

  def validate_before_and_prediction
    before = {
      "schema" => "cohort_release_state_v1",
      "cohort_id" => cohort_id,
      "coach_workspace_id" => coach_workspace_id,
      "release_count" => cohort_release.release_number - 1,
      "latest_release_id" => previous_release&.id,
      "latest_release_number" => previous_release&.release_number,
      "latest_bundle_digest" => previous_release&.bundle_digest,
      "participant_runtime_changed" => false
    }
    predicted = before.merge(
      "release_count" => cohort_release.release_number,
      "latest_release_id" => nil,
      "latest_release_id_pending" => true,
      "latest_release_number" => cohort_release.release_number,
      "latest_bundle_digest" => cohort_release.bundle_digest
    )
    errors.add(:before_snapshot, "does not match the prior release state") unless before_snapshot == before
    unless predicted_after_snapshot == predicted
      errors.add(:predicted_after_snapshot, "does not match the linked release")
    end
  end

  def previous_release
    @previous_release ||= cohort.cohort_releases.find_by(release_number: cohort_release.release_number - 1)
  end

  def sealed_record_is_immutable
    errors.add(:base, "coach operation executions are immutable") if changed?
  end

  def prevent_destroy
    errors.add(:base, "coach operation executions cannot be deleted")
    throw :abort
  end

  def secure_match?(left, right)
    left.present? && right.present? && left.bytesize == right.bytesize &&
      ActiveSupport::SecurityUtils.secure_compare(left, right)
  end
end
