# frozen_string_literal: true

require "digest"
require "json"

class CoachPhraseProposal < ApplicationRecord
  STATUSES = %w[draft submitted rejected superseded].freeze
  PAYLOAD_KEYS = %w[text meaning allowed_contexts prohibited_contexts frequency caution].freeze
  DIGEST_FIELDS = %w[
    source_checksum_sha256 source_segment_digest phrase_digest approved_content_digest
    source_provenance_digest proposal_digest
  ].freeze

  belongs_to :coach_workspace
  belongs_to :coach_content_source
  belongs_to :coach_content_source_attempt
  belongs_to :coach_content_source_candidate
  belongs_to :coach_content_item_version
  belongs_to :proposed_by_user, class_name: "User"
  has_one :attestation, class_name: "CoachPhraseAttestation", dependent: :restrict_with_exception
  has_many :persona_promotions, class_name: "CoachPersonaPhrasePromotion", dependent: :restrict_with_exception

  validates :status, inclusion: { in: STATUSES }
  validates :revision, numericality: { only_integer: true, greater_than: 0 }
  validates(*DIGEST_FIELDS, format: { with: /\A[0-9a-f]{64}\z/ })
  validate :payload_shape
  validate :linked_records_match
  validate :digest_matches_snapshot
  validate :sealed_payload_is_immutable, on: :update
  validate :status_transition_is_valid, on: :update
  validate :lifecycle_is_coherent

  before_validation :normalize_payloads
  before_destroy :prevent_destroy

  class << self
    def snapshot(attributes)
      raw = attributes.respond_to?(:attributes) ? attributes.attributes : attributes.to_h
      payload = raw.stringify_keys
      {
        "workspace_id" => record_id(payload, "coach_workspace", "coach_workspace_id"),
        "source_id" => record_id(payload, "coach_content_source", "coach_content_source_id"),
        "source_attempt_id" => record_id(payload, "coach_content_source_attempt", "coach_content_source_attempt_id"),
        "source_candidate_id" => record_id(payload, "coach_content_source_candidate", "coach_content_source_candidate_id"),
        "content_item_version_id" => record_id(payload, "coach_content_item_version", "coach_content_item_version_id"),
        "proposed_by_user_id" => record_id(payload, "proposed_by_user", "proposed_by_user_id"),
        "phrase_payload" => Mia::PhraseManifest.canonicalize(payload.fetch("phrase_payload", {})),
        "evidence_locator" => Mia::PhraseManifest.canonicalize(payload.fetch("evidence_locator", {})),
        "evidence_start_byte" => payload["evidence_start_byte"],
        "evidence_end_byte" => payload["evidence_end_byte"],
        "source_checksum_sha256" => payload["source_checksum_sha256"],
        "source_segment_digest" => payload["source_segment_digest"],
        "phrase_digest" => payload["phrase_digest"],
        "approved_content_digest" => payload["approved_content_digest"],
        "source_provenance_digest" => payload["source_provenance_digest"]
      }
    end

    def digest_for(attributes)
      Digest::SHA256.hexdigest(JSON.generate(snapshot(attributes)).b)
    end

    private

    def record_id(payload, association, foreign_key)
      payload[foreign_key] || payload[association]&.id
    end
  end

  def evidence_digest
    Digest::SHA256.hexdigest(JSON.generate(self.class.snapshot(self).slice(
      "source_id", "source_attempt_id", "source_candidate_id", "content_item_version_id",
      "evidence_locator", "evidence_start_byte", "evidence_end_byte", "source_checksum_sha256",
      "source_segment_digest", "phrase_digest", "approved_content_digest", "source_provenance_digest"
    )).b)
  end

  def submitted?
    status == "submitted"
  end

  def integrity_valid?
    return false unless phrase_payload.is_a?(Hash) && phrase_payload.keys.sort == PAYLOAD_KEYS.sort
    return false unless linked_records_match? && lifecycle_coherent?
    return false unless revision.to_i.positive? && evidence_start_byte.to_i >= 0 && evidence_end_byte.to_i > evidence_start_byte.to_i
    return false unless DIGEST_FIELDS.all? { |field| public_send(field).to_s.match?(/\A[0-9a-f]{64}\z/) }

    expected = self.class.digest_for(self)
    return false unless secure_match?(proposal_digest, expected)
    return false unless secure_match?(source_checksum_sha256, coach_content_source.checksum_sha256)
    return false unless secure_match?(approved_content_digest, coach_content_item_version.content_digest)
    return false unless secure_match?(source_provenance_digest, coach_content_item_version.source_provenance&.provenance_digest)
    return false unless secure_match?(phrase_digest, Digest::SHA256.hexdigest(phrase_payload.fetch("text").to_s.b))

    Mia::PersonaSchema.validate_phrase_authoring_payload!(phrase_payload)
    coach_content_item_version.integrity_valid?
  rescue ActiveRecord::RecordNotFound, KeyError, Mia::PersonaSchema::InvalidConfiguration
    false
  end

  def self.supersede_open_for_source!(source, at: Time.current)
    ids = left_outer_joins(:attestation)
      .where(coach_content_source_id: source.id, status: %w[draft submitted], coach_phrase_attestations: { id: nil })
      .pluck(:id)
    where(id: ids).order(:id).lock.each do |proposal|
      proposal.update!(status: "superseded", superseded_at: at)
    end
  end

  private

  def normalize_payloads
    self.phrase_payload = Mia::PersonaSchema.normalize(phrase_payload).slice(*PAYLOAD_KEYS) if phrase_payload.respond_to?(:to_h)
    self.evidence_locator = Mia::PersonaSchema.normalize(evidence_locator) if evidence_locator.respond_to?(:to_h)
  end

  def payload_shape
    unless phrase_payload.is_a?(Hash) && phrase_payload.keys.sort == PAYLOAD_KEYS.sort
      errors.add(:phrase_payload, "must contain the exact approved phrase fields")
    end
  end

  def linked_records_match
    return if linked_records_match?

    errors.add(:base, "phrase proposal source chain is invalid")
  end

  def linked_records_match?
    return false unless coach_workspace && coach_content_source && coach_content_source_attempt && coach_content_source_candidate && coach_content_item_version

    item = coach_content_item_version.coach_content_item
    provenance = coach_content_item_version.source_provenance
    coach_content_source.scope == "coach" && coach_content_source.coach_workspace_id == coach_workspace_id &&
      item.scope == "coach" && item.coach_workspace_id == coach_workspace_id && coach_content_item_version.kind == "phrase" &&
      coach_content_source_attempt.coach_content_source_id == coach_content_source_id &&
      coach_content_source_candidate.coach_content_source_id == coach_content_source_id &&
      coach_content_source_candidate.coach_content_source_attempt_id == coach_content_source_attempt_id &&
      coach_content_source_candidate.accepted_content_item_id == item.id &&
      provenance&.coach_content_source_id == coach_content_source_id &&
      provenance&.coach_content_source_attempt_id == coach_content_source_attempt_id &&
      provenance&.coach_content_source_candidate_id == coach_content_source_candidate_id
  end

  def digest_matches_snapshot
    return unless proposal_digest.present?

    expected = self.class.digest_for(self)
    errors.add(:proposal_digest, "must match the sealed proposal") unless ActiveSupport::SecurityUtils.secure_compare(proposal_digest, expected)
  end

  def sealed_payload_is_immutable
    return if status_was == "draft"

    protected_fields = self.class.snapshot(self).keys.map { |key| key == "workspace_id" ? "coach_workspace_id" : key }
    protected_fields += %w[
      coach_content_source_id coach_content_source_attempt_id coach_content_source_candidate_id
      coach_content_item_version_id proposed_by_user_id revision submitted_at
    ]
    errors.add(:base, "submitted phrase proposal evidence is immutable") if changes_to_save.keys.intersect?(protected_fields.uniq)
  end

  def status_transition_is_valid
    allowed = {
      "draft" => %w[draft submitted superseded],
      "submitted" => %w[submitted rejected superseded],
      "rejected" => %w[rejected],
      "superseded" => %w[superseded]
    }
    return if status.in?(allowed.fetch(status_was, []))

    errors.add(:status, "cannot move backward in the phrase review lifecycle")
  end

  def lifecycle_is_coherent
    errors.add(:submitted_at, "does not match the proposal lifecycle") unless lifecycle_coherent?
    errors.add(:superseded_at, "must match superseded status") unless (status == "superseded") == superseded_at.present?
  end

  def lifecycle_coherent?
    case status
    when "draft"
      submitted_at.blank? && superseded_at.blank?
    when "submitted", "rejected"
      submitted_at.present? && superseded_at.blank?
    when "superseded"
      superseded_at.present?
    else
      false
    end
  end

  def secure_match?(left, right)
    left.to_s.bytesize == right.to_s.bytesize && ActiveSupport::SecurityUtils.secure_compare(left.to_s, right.to_s)
  end

  def prevent_destroy
    errors.add(:base, "phrase proposals cannot be deleted")
    throw :abort
  end
end
