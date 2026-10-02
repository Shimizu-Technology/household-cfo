# frozen_string_literal: true

class CoachPersonaPublicationEvent < ApplicationRecord
  EVENT_TYPES = %w[publish rollback].freeze

  belongs_to :coach_persona, inverse_of: :publication_events
  belongs_to :coach_persona_version, inverse_of: :publication_events
  belongs_to :actor_user, class_name: "User", inverse_of: :coach_persona_publication_events
  belongs_to :source_version, class_name: "CoachPersonaVersion", optional: true

  validates :event_type, inclusion: { in: EVENT_TYPES }
  validates :release_gate_version, inclusion: { in: %w[gate_v1 gate_v2] }
  validates :release_evidence_digest, format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true
  validate :actor_is_staff
  validate :versions_belong_to_persona
  validate :source_matches_event_type
  validate :release_evidence_matches_version
  validate :persisted_event_is_immutable, on: :update

  before_destroy :prevent_destroy

  private

  def actor_is_staff
    errors.add(:actor_user, "must be a coach or admin") unless actor_user&.staff?
  end

  def versions_belong_to_persona
    errors.add(:coach_persona_version, "must belong to this persona") if coach_persona_version&.coach_persona != coach_persona
    errors.add(:source_version, "must belong to this persona") if source_version.present? && source_version.coach_persona != coach_persona
  end

  def source_matches_event_type
    if event_type == "rollback" && source_version.nil?
      errors.add(:source_version, "is required for a rollback")
    elsif event_type == "publish" && source_version.present?
      errors.add(:source_version, "must be blank for a publish")
    end
  end

  def release_evidence_matches_version
    return unless coach_persona_version

    errors.add(:release_gate_version, "must match the published version") unless release_gate_version == coach_persona_version.release_gate_version
    errors.add(:release_evidence_digest, "must match the published version") unless release_evidence_digest == coach_persona_version.release_evidence_digest
    unless phrase_audience_attestation_digests == coach_persona_version.phrase_audience_attestation_digests
      errors.add(:phrase_audience_attestation_digests, "must match the published version")
    end
  end

  def persisted_event_is_immutable
    errors.add(:base, "publication events are immutable") if has_changes_to_save?
  end

  def prevent_destroy
    errors.add(:base, "publication events cannot be deleted")
    throw :abort
  end
end
