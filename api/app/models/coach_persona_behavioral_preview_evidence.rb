# frozen_string_literal: true

require "digest"
require "json"

class CoachPersonaBehavioralPreviewEvidence < ApplicationRecord
  PRIVACY_SCOPE = "no_saved_participant_or_household_data"

  belongs_to :release_candidate, class_name: "CoachPersonaReleaseCandidate",
    foreign_key: :coach_persona_release_candidate_id
  belongs_to :generated_by_user, class_name: "User"
  has_many :persona_versions, class_name: "CoachPersonaVersion", dependent: :restrict_with_exception

  validates :prompt, presence: true, length: { maximum: 2_000 }
  validates :output, presence: true, length: { maximum: 4_000 }
  validates :response_source, inclusion: { in: [ "live_model" ] }
  validates :model_identifier, :provider_request_id, presence: true, length: { maximum: 200 },
    format: { with: /\A[^\s[:cntrl:]]+\z/ }
  validates :privacy_scope, inclusion: { in: [ PRIVACY_SCOPE ] }
  validates :context_digest, :candidate_digest, :config_digest, :content_manifest_digest,
    :phrase_manifest_digest, :evidence_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :generated_at, presence: true
  validate :candidate_snapshot_matches
  validate :context_matches_current_preview, on: :create
  validate :generator_can_publish
  validate :digest_matches_snapshot
  validate :immutable_record, on: :update
  before_destroy :prevent_destroy

  def self.digest_for(value)
    record = value.respond_to?(:attributes) ? value.attributes : value.stringify_keys
    Digest::SHA256.hexdigest(JSON.generate(Mia::PhraseManifest.canonicalize({
      schema: "persona_behavioral_preview_evidence_v1",
      candidate_id: record["coach_persona_release_candidate_id"],
      candidate_digest: record["candidate_digest"],
      config_digest: record["config_digest"],
      content_manifest_digest: record["content_manifest_digest"],
      phrase_manifest_digest: record["phrase_manifest_digest"],
      prompt: record["prompt"],
      output: record["output"],
      response_source: record["response_source"],
      model_identifier: record["model_identifier"],
      provider_request_id: record["provider_request_id"],
      privacy_scope: record["privacy_scope"],
      context_digest: record["context_digest"],
      generated_by_user_id: record["generated_by_user_id"],
      generated_at: record["generated_at"]&.in_time_zone("UTC")&.iso8601(6)
    })).b)
  end

  def integrity_valid?
    release_candidate&.integrity_valid? && provider_provenance_valid? && candidate_snapshot_matches? &&
      evidence_digest.present? && ActiveSupport::SecurityUtils.secure_compare(evidence_digest, self.class.digest_for(self))
  end

  def provider_provenance_valid?
    [ model_identifier, provider_request_id ].all? do |value|
      value.to_s.present? && value.to_s.length <= 200 && value.to_s.match?(/\A[^\s[:cntrl:]]+\z/)
    end
  end

  private

  def candidate_snapshot_matches?
    release_candidate && candidate_digest == release_candidate.manifest_digest &&
      config_digest == release_candidate.config_digest &&
      content_manifest_digest == release_candidate.content_manifest_digest &&
      phrase_manifest_digest == release_candidate.phrase_manifest_digest
  end

  def candidate_snapshot_matches
    errors.add(:base, "behavioral preview does not match the sealed release candidate") unless candidate_snapshot_matches?
  end

  def context_matches_current_preview
    return if context_digest == Mia::PersonaPreviewer.context_digest

    errors.add(:context_digest, "must match the current preview context")
  end

  def generator_can_publish
    return if release_candidate&.coach_persona&.coach_workspace&.allows?(generated_by_user, :publish)

    errors.add(:generated_by_user, "must be able to publish the persona workspace")
  end

  def digest_matches_snapshot
    errors.add(:evidence_digest, "must match the behavioral preview") unless evidence_digest.present? &&
      ActiveSupport::SecurityUtils.secure_compare(evidence_digest, self.class.digest_for(self))
  end

  def immutable_record
    errors.add(:base, "behavioral preview evidence is immutable") if has_changes_to_save?
  end

  def prevent_destroy
    errors.add(:base, "behavioral preview evidence cannot be deleted")
    throw :abort
  end
end
