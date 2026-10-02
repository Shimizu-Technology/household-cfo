# frozen_string_literal: true

require "digest"
require "json"

class CoachPersonaReleaseCandidate < ApplicationRecord
  belongs_to :coach_persona
  belongs_to :created_by_user, class_name: "User"
  has_many :evaluation_runs, class_name: "CoachPersonaEvaluationRun", dependent: :restrict_with_exception
  has_many :phrase_audience_attestations, class_name: "CoachPhraseAudienceAttestation", dependent: :restrict_with_exception
  has_many :persona_versions, class_name: "CoachPersonaVersion", dependent: :restrict_with_exception

  validates :draft_revision, numericality: { only_integer: true, greater_than: 0 }
  validates :config_digest, :content_manifest_digest, :phrase_manifest_digest, :audience_digest,
    :manifest_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :sealed_at, presence: true
  validate :snapshots_are_bounded
  validate :creator_can_edit_persona
  validate :manifest_matches_snapshot
  validate :immutable_record, on: :update
  before_destroy :prevent_destroy

  def self.digest_for(manifest)
    Digest::SHA256.hexdigest(JSON.generate(Mia::PhraseManifest.canonicalize(manifest)).b)
  end

  def current_for?(persona)
    return false unless persona.id == coach_persona_id && integrity_valid?

    expected = Mia::PersonaRelease::CandidateBuilder.snapshot(persona)
    manifest_digest.bytesize == expected.fetch(:manifest_digest).bytesize &&
      ActiveSupport::SecurityUtils.secure_compare(manifest_digest, expected.fetch(:manifest_digest))
  rescue ArgumentError, KeyError
    false
  end

  def integrity_valid?
    manifest_matches_snapshot?
  end

  private

  def manifest_matches_snapshot
    errors.add(:manifest_digest, "must match the sealed release candidate") unless manifest_matches_snapshot?
  end

  def manifest_matches_snapshot?
    expected_manifest = {
      "schema" => "persona_release_candidate_v2",
      "persona_id" => coach_persona_id,
      "draft_revision" => draft_revision,
      "config_digest" => config_digest,
      "content_manifest_digest" => content_manifest_digest,
      "phrase_manifest_digest" => phrase_manifest_digest,
      "audience_digest" => audience_digest,
      "phrase_artifacts" => phrase_artifacts_snapshot
    }
    canonical = Mia::PhraseManifest.canonicalize(manifest)
    expected = Mia::PhraseManifest.canonicalize(expected_manifest)
    audience_matches = audience_digest.present? &&
      ActiveSupport::SecurityUtils.secure_compare(audience_digest, self.class.digest_for(audience_snapshot))
    audience_matches && JSON.generate(canonical) == JSON.generate(expected) &&
      manifest_digest.present? && ActiveSupport::SecurityUtils.secure_compare(manifest_digest, self.class.digest_for(expected))
  end

  def snapshots_are_bounded
    errors.add(:audience_snapshot, "is too large") if JSON.generate(audience_snapshot).bytesize > 8.kilobytes
    errors.add(:phrase_artifacts_snapshot, "is too large") if JSON.generate(phrase_artifacts_snapshot).bytesize > 40.kilobytes
  end

  def creator_can_edit_persona
    return if coach_persona&.coach_workspace&.allows?(created_by_user, :edit)

    errors.add(:created_by_user, "must be able to edit the persona workspace")
  end

  def immutable_record
    errors.add(:base, "release candidates are immutable") if has_changes_to_save?
  end

  def prevent_destroy
    errors.add(:base, "release candidates cannot be deleted")
    throw :abort
  end
end
