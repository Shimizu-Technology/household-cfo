# frozen_string_literal: true

require "digest"

class CoachPersonaVersion < ApplicationRecord
  belongs_to :coach_persona, inverse_of: :versions
  belongs_to :published_by_user, class_name: "User", inverse_of: :published_coach_persona_versions
  belongs_to :source_version, class_name: "CoachPersonaVersion", optional: true
  belongs_to :release_candidate, class_name: "CoachPersonaReleaseCandidate",
    foreign_key: :coach_persona_release_candidate_id, optional: true
  belongs_to :evaluation_run, class_name: "CoachPersonaEvaluationRun",
    foreign_key: :coach_persona_evaluation_run_id, optional: true
  belongs_to :evaluation_approval, class_name: "CoachPersonaEvaluationApproval",
    foreign_key: :coach_persona_evaluation_approval_id, optional: true
  belongs_to :behavioral_preview_evidence, class_name: "CoachPersonaBehavioralPreviewEvidence",
    foreign_key: :coach_persona_behavioral_preview_evidence_id, optional: true

  has_many :derived_versions,
    class_name: "CoachPersonaVersion",
    foreign_key: :source_version_id,
    dependent: :restrict_with_exception,
    inverse_of: :source_version
  has_many :cohort_persona_assignments, dependent: :restrict_with_exception, inverse_of: :coach_persona_version
  has_many :chat_messages, dependent: :restrict_with_exception, inverse_of: :coach_persona_version
  has_many :content_pack_links,
    -> { order(:position) },
    class_name: "CoachPersonaVersionContentPack",
    dependent: :restrict_with_exception,
    inverse_of: :coach_persona_version
  has_many :content_pack_versions, through: :content_pack_links, source: :coach_content_pack_version
  has_many :phrase_artifact_links,
    -> { order(:position) },
    class_name: "CoachPersonaVersionPhraseArtifact",
    dependent: :restrict_with_exception,
    inverse_of: :coach_persona_version
  has_many :publication_events,
    class_name: "CoachPersonaPublicationEvent",
    dependent: :restrict_with_exception,
    inverse_of: :coach_persona_version
  has_many :draft_restore_events,
    class_name: "CoachPersonaDraftRestoreEvent",
    foreign_key: :source_version_id,
    dependent: :restrict_with_exception,
    inverse_of: :source_version

  validates :version_number, numericality: { only_integer: true, greater_than: 0 }, uniqueness: { scope: :coach_persona_id }
  validates :config_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :content_manifest_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :phrase_manifest_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :release_gate_version, inclusion: { in: %w[gate_v1 gate_v2] }
  validates :release_manifest_digest, :audience_digest, :release_evidence_digest,
    format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true
  validates :behavioral_preview_digest, format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true
  validates :release_evidence_schema, inclusion: { in: %w[persona_release_evidence_v2 persona_release_evidence_v3] }, allow_nil: true
  validate :publisher_is_staff
  validate :config_matches_schema_and_digest
  validate :phrase_artifact_provenance
  validate :source_version_belongs_to_persona
  validate :release_gate_shape
  validate :published_record_is_immutable, on: :update

  before_validation :normalize_config, on: :create
  before_destroy :prevent_destroy

  def self.content_manifest_entry(pack_version, position:)
    {
      position: position,
      pack_version_id: pack_version.id,
      pack_id: pack_version.coach_content_pack_id,
      pack_version_number: pack_version.version_number,
      content_digest: pack_version.content_digest
    }
  end

  def self.content_manifest_digest_for(pack_versions)
    entries = Array(pack_versions).each_with_index.map { |version, position| content_manifest_entry(version, position: position) }
    Digest::SHA256.hexdigest(JSON.generate(entries).b)
  end

  def sealed?
    sealed_at.present?
  end

  def seal_manifests!
    raise ArgumentError, "Published persona version is already sealed" if sealed?

    content_digest = self.class.content_manifest_digest_for(content_pack_links.includes(:coach_content_pack_version).order(:position).map(&:coach_content_pack_version))
    phrase_entries = phrase_artifact_links.includes(coach_persona_phrase_promotion: %i[coach_phrase_proposal coach_phrase_attestation]).order(:position).map do |link|
      Mia::PhraseManifest.entry(link, position: link.position)
    end
    phrase_digest = Mia::PhraseManifest.digest_for(phrase_entries)
    if release_gate_version == "gate_v2" && !release_evidence_valid_for?(
      content_digest: content_digest, phrase_digest: phrase_digest
    )
      raise ArgumentError, "gate_v2 release evidence does not match the sealed manifests"
    end
    update_columns(
      content_manifest_digest: content_digest,
      phrase_manifest_digest: phrase_digest,
      sealed_at: Time.current,
      updated_at: Time.current
    )
    self.content_manifest_digest = content_digest
    self.phrase_manifest_digest = phrase_digest
    self
  end

  alias_method :seal_content_manifest!, :seal_manifests!

  def content_manifest_valid?
    return false unless sealed?

    versions = content_pack_links.includes(
      coach_content_pack_version: { entries: { coach_content_item_version: { source_provenance: %i[coach_content_source coach_content_source_attempt coach_content_source_candidate] } } }
    ).order(:position).map(&:coach_content_pack_version)
    content_manifest_valid_with_versions?(versions)
  end

  def content_manifest_valid_with_versions?(versions)
    return false unless sealed?
    return false unless versions.all?(&:manifest_valid?)

    expected = self.class.content_manifest_digest_for(versions)
    ActiveSupport::SecurityUtils.secure_compare(content_manifest_digest, expected)
  end

  def phrase_manifest_valid?
    return false unless sealed?

    approved = Array(config.to_h["phrases"]).each_with_index.filter_map do |phrase, position|
      [ phrase, position ] if phrase.is_a?(Hash) && phrase["provenance"] == "approved_source"
    end
    links = phrase_artifact_links.includes(
      coach_persona_phrase_promotion: %i[coach_phrase_proposal coach_phrase_attestation]
    ).order(:position).to_a
    return false unless approved.length == links.length

    valid = approved.zip(links).all? do |(artifact, position), link|
      link.position == position && link.integrity_valid? &&
        link.artifact_id.to_s == artifact["artifact_id"].to_s &&
        link.artifact_fingerprint == artifact["fingerprint"] &&
        link.coach_persona_phrase_promotion.artifact == artifact
    end
    return false unless valid

    expected = Mia::PhraseManifest.digest_for(links.map { |link| Mia::PhraseManifest.entry(link, position: link.position) })
    phrase_manifest_digest.to_s.bytesize == expected.bytesize &&
      ActiveSupport::SecurityUtils.secure_compare(phrase_manifest_digest, expected)
  end

  def publication_digest
    payload = { config: config_digest, content: content_manifest_digest, phrases: phrase_manifest_digest }
    if release_gate_version == "gate_v2"
      payload[:release] = {
        candidate: release_manifest_digest,
        audience: audience_digest,
        evidence: release_evidence_digest,
        behavioral_preview: behavioral_preview_digest
      }
    end
    Digest::SHA256.hexdigest(JSON.generate(payload).b)
  end

  def release_evidence_valid?
    return true if release_gate_version == "gate_v1"
    return false unless release_candidate&.integrity_valid? && evaluation_run&.passed_and_valid? && evaluation_approval&.integrity_valid?
    return false unless evaluation_run.coach_persona_release_candidate_id == release_candidate.id &&
      evaluation_approval.coach_persona_evaluation_run_id == evaluation_run.id
    release_evidence_valid_for?(content_digest: content_manifest_digest, phrase_digest: phrase_manifest_digest)
  end

  def release_evidence_valid_for?(content_digest:, phrase_digest:)
    return false unless release_candidate&.integrity_valid? && evaluation_run&.passed_and_valid? && evaluation_approval&.integrity_valid?
    return false unless evaluation_run.coach_persona_release_candidate_id == release_candidate.id &&
      evaluation_approval.coach_persona_evaluation_run_id == evaluation_run.id
    return false unless config_digest == release_candidate.config_digest && content_digest == release_candidate.content_manifest_digest
    return false unless phrase_digest == release_candidate.phrase_manifest_digest && audience_digest == release_candidate.audience_digest
    return false unless release_manifest_digest == release_candidate.manifest_digest

    attestation_digests = Array(phrase_audience_attestation_digests)
    return false unless attestation_digests.all? { |digest| digest.to_s.match?(/\A[0-9a-f]{64}\z/) }

    attestations = release_candidate.phrase_audience_attestations
      .where(attestation_digest: attestation_digests).to_a
      .sort_by { |attestation| attestation.artifact_id.to_s }
    return false unless attestations.map(&:attestation_digest) == attestation_digests

    preview = release_evidence_schema == "persona_release_evidence_v3" ? behavioral_preview_evidence : nil
    return false if release_evidence_schema == "persona_release_evidence_v3" &&
      (!preview&.integrity_valid? || behavioral_preview_digest != preview.evidence_digest || preview.release_candidate != release_candidate)
    expected = Mia::PersonaRelease::Evidence.digest_for(
      candidate: release_candidate,
      run: evaluation_run,
      approval: evaluation_approval,
      attestations: attestations,
      behavioral_preview: preview
    )
    release_evidence_digest == expected && Array(release_candidate.phrase_artifacts_snapshot).all? do |artifact|
      attestations.any? do |attestation|
        attestation.artifact_id.to_s == artifact.fetch("artifact_id").to_s &&
          attestation.decision == "approved" && attestation.integrity_valid?
      end
    end
  rescue KeyError
    false
  end

  private

  def normalize_config
    self.config = Mia::PersonaSchema.normalize(config) if config.is_a?(Hash)
  end

  def publisher_is_staff
    errors.add(:published_by_user, "must be a coach or admin") unless published_by_user&.staff?
  end

  def config_matches_schema_and_digest
    schema_errors = Mia::PersonaSchema.errors(config)
    schema_errors.each { |message| errors.add(:config, message) }
    return if schema_errors.any?
    return if config_digest == Mia::PersonaSchema.digest(config)

    errors.add(:config_digest, "must match the canonical configuration digest")
  end

  def phrase_artifact_provenance
    Array(config.to_h["phrases"]).each_with_index do |phrase, index|
      next unless phrase.is_a?(Hash)

      source_user_id = Integer(phrase["source_user_id"], exception: false)
      captured_role = phrase["source_role_at_capture"]
      valid = if phrase["provenance"] == "coach_authored"
        source_user_id.present? && captured_role.in?(%w[admin coach])
      elsif phrase["provenance"] == "participant_supplied"
        source_user_id.present? && captured_role == "participant"
      elsif phrase["provenance"] == "approved_source"
        source_user_id.present? && captured_role.in?(%w[admin coach])
      end
      errors.add(:config, "$.phrases[#{index}] has invalid provenance") unless valid
    end
  end

  def source_version_belongs_to_persona
    return if source_version.nil? || source_version.coach_persona == coach_persona

    errors.add(:source_version, "must belong to the same persona")
  end

  def release_gate_shape
    evidence_fields = [ release_candidate, evaluation_run, evaluation_approval, release_manifest_digest, audience_digest, release_evidence_digest ]
    if release_gate_version == "gate_v1"
      legacy_fields = evidence_fields + [ behavioral_preview_evidence, behavioral_preview_digest, release_evidence_schema ]
      errors.add(:base, "legacy gate_v1 versions cannot claim v2 release evidence") if legacy_fields.any?(&:present?)
      errors.add(:phrase_audience_attestation_digests, "must be empty for legacy versions") if phrase_audience_attestation_digests.present?
      return
    end

    errors.add(:base, "gate_v2 versions require complete release evidence") unless evidence_fields.all?(&:present?)
    unless phrase_audience_attestation_digests.is_a?(Array) &&
        phrase_audience_attestation_digests.all? { |digest| digest.to_s.match?(/\A[0-9a-f]{64}\z/) }
      errors.add(:phrase_audience_attestation_digests, "must contain sealed review digests")
    end
    if release_evidence_schema == "persona_release_evidence_v3"
      errors.add(:base, "gate_v2 v3 versions require behavioral preview evidence") unless behavioral_preview_evidence && behavioral_preview_digest.present?
    elsif release_evidence_schema != "persona_release_evidence_v2"
      errors.add(:release_evidence_schema, "must identify the sealed evidence format")
    end
    errors.add(:release_candidate, "must belong to this persona") if release_candidate && release_candidate.coach_persona_id != coach_persona_id
    if evaluation_run && release_candidate && evaluation_run.coach_persona_release_candidate_id != release_candidate.id
      errors.add(:evaluation_run, "must belong to the release candidate")
    end
    if evaluation_approval && evaluation_run && evaluation_approval.coach_persona_evaluation_run_id != evaluation_run.id
      errors.add(:evaluation_approval, "must belong to the evaluation run")
    end
  end

  def published_record_is_immutable
    errors.add(:base, "published persona versions are immutable") if has_changes_to_save?
  end

  def prevent_destroy
    errors.add(:base, "published persona versions cannot be deleted")
    throw :abort
  end
end
