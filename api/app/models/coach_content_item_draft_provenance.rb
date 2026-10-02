# frozen_string_literal: true

require "digest"

class CoachContentItemDraftProvenance < ApplicationRecord
  belongs_to :coach_content_item
  belongs_to :coach_content_source
  belongs_to :coach_content_source_attempt
  belongs_to :coach_content_source_candidate
  belongs_to :accepted_by_user, class_name: "User"

  validates :source_filename, :source_content_type, :attempt_provider, :attempt_model,
    :attempt_prompt_version, :attempt_schema_version, presence: true
  validates :source_byte_size, numericality: { only_integer: true, greater_than: 0 }
  validates :source_checksum_sha256, :candidate_content_digest, :candidate_original_proposal_digest, :evidence_excerpt_digest,
    :provenance_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :candidate_revision, numericality: { only_integer: true, greater_than: 0 }
  validates :candidate_review_action, inclusion: { in: %w[accepted] }
  validates :accepted_at, presence: true
  validate :linked_records_match
  validate :digest_matches_snapshot
  validate :immutable_record, on: :update
  before_destroy :prevent_destroy

  class << self
    def create_from_candidate!(candidate:, item:)
      source = candidate.coach_content_source
      attempt = candidate.coach_content_source_attempt
      attributes = {
        coach_content_item: item,
        coach_content_source: source,
        coach_content_source_attempt: attempt,
        coach_content_source_candidate: candidate,
        source_filename: provenance_filename_for(source.filename),
        source_content_type: source.content_type,
        source_byte_size: source.byte_size,
        source_checksum_sha256: source.checksum_sha256,
        attempt_provider: attempt.provider,
        attempt_model: attempt.model,
        attempt_prompt_version: attempt.prompt_version,
        attempt_schema_version: attempt.schema_version,
        candidate_content_digest: candidate.content_digest,
        candidate_original_proposal_digest: candidate.original_proposal_digest,
        candidate_revision: candidate.revision,
        candidate_review_action: candidate.status,
        accepted_by_user: candidate.reviewed_by_user,
        accepted_at: candidate.reviewed_at,
        evidence_locator: candidate.evidence_locator,
        evidence_excerpt_digest: candidate.evidence_locator.fetch("excerpt_digest")
      }
      record = new(attributes)
      record.provenance_digest = digest_for(record.send(:attributes_for_digest))
      record.save!
      record
    end

    def digest_for(attributes)
      Digest::SHA256.hexdigest(JSON.generate(snapshot(attributes)).b)
    end

    def provenance_filename_for(filename)
      extension = File.extname(filename.to_s).downcase.presence_in(%w[.pdf .docx .txt .md .vtt .srt]) || ".source"
      "uploaded-source#{extension}"
    end

    def snapshot(attributes)
      {
        source_id: record_id(attributes, :coach_content_source, :coach_content_source_id),
        source_attempt_id: record_id(attributes, :coach_content_source_attempt, :coach_content_source_attempt_id),
        source_candidate_id: record_id(attributes, :coach_content_source_candidate, :coach_content_source_candidate_id),
        source_filename: attributes[:source_filename],
        source_content_type: attributes[:source_content_type],
        source_byte_size: attributes[:source_byte_size],
        source_checksum_sha256: attributes[:source_checksum_sha256],
        attempt_provider: attributes[:attempt_provider],
        attempt_model: attributes[:attempt_model],
        attempt_prompt_version: attributes[:attempt_prompt_version],
        attempt_schema_version: attributes[:attempt_schema_version],
        candidate_content_digest: attributes[:candidate_content_digest],
        candidate_original_proposal_digest: attributes[:candidate_original_proposal_digest],
        candidate_revision: attributes[:candidate_revision],
        candidate_review_action: attributes[:candidate_review_action],
        accepted_by_user_id: record_id(attributes, :accepted_by_user, :accepted_by_user_id),
        accepted_at: canonical_time(attributes[:accepted_at]),
        evidence_locator: attributes[:evidence_locator].to_h.sort.to_h,
        evidence_excerpt_digest: attributes[:evidence_excerpt_digest]
      }
    end

    private

    def canonical_time(value)
      value&.in_time_zone("UTC")&.iso8601(6)
    end

    def record_id(attributes, association, foreign_key)
      attributes[foreign_key] || attributes[association]&.id
    end
  end

  def integrity_valid?
    provenance_digest.present? &&
      ActiveSupport::SecurityUtils.secure_compare(provenance_digest, self.class.digest_for(attributes_for_digest)) &&
      linked_identity_valid?
  end

  def attributes_for_version
    self.class.snapshot(attributes_for_digest).except(:source_id, :source_attempt_id, :source_candidate_id).merge(
      coach_content_source_id: coach_content_source_id,
      coach_content_source_attempt_id: coach_content_source_attempt_id,
      coach_content_source_candidate_id: coach_content_source_candidate_id
    )
  end

  private

  def linked_identity_valid?
    source = coach_content_source
    attempt = coach_content_source_attempt
    candidate = coach_content_source_candidate
    item = coach_content_item
    return false unless source && attempt && candidate && item

    item.created_by_user_id == source.created_by_user_id && item.coach_workspace_id == source.coach_workspace_id && item.scope == source.scope &&
      source_filename == self.class.provenance_filename_for(source.filename) &&
      source_content_type == source.content_type && source_byte_size == source.byte_size && source_checksum_sha256 == source.checksum_sha256 &&
      attempt.coach_content_source_id == source.id && attempt_provider == attempt.provider && attempt_model == attempt.model &&
      attempt_prompt_version == attempt.prompt_version && attempt_schema_version == attempt.schema_version &&
      candidate.coach_content_source_id == source.id && candidate.coach_content_source_attempt_id == attempt.id &&
      candidate.status == candidate_review_action && candidate_review_action == "accepted" && candidate.accepted_content_item_id == item.id &&
      candidate_original_proposal_digest == candidate.original_proposal_digest && candidate_revision == candidate.revision &&
      accepted_by_user_id == candidate.reviewed_by_user_id && accepted_at == candidate.reviewed_at &&
      candidate_content_digest == candidate.content_digest && candidate.content_digest == candidate.review_digest &&
      evidence_locator == candidate.evidence_locator && evidence_excerpt_digest == candidate.evidence_locator["excerpt_digest"]
  end

  def attributes_for_digest
    attributes.symbolize_keys.merge(
      coach_content_source: coach_content_source,
      coach_content_source_attempt: coach_content_source_attempt,
      coach_content_source_candidate: coach_content_source_candidate
    )
  end

  def linked_records_match
    return if coach_content_source.nil? || coach_content_source_attempt.nil? || coach_content_source_candidate.nil? || coach_content_item.nil?

    errors.add(:base, "source attempt does not belong to the source") unless coach_content_source_attempt.coach_content_source_id == coach_content_source_id
    errors.add(:base, "candidate does not belong to the source attempt") unless coach_content_source_candidate.coach_content_source_attempt_id == coach_content_source_attempt_id
    errors.add(:base, "candidate does not belong to the source") unless coach_content_source_candidate.coach_content_source_id == coach_content_source_id
    allowed_owner = coach_content_source.created_by_user_id == coach_content_item.created_by_user_id &&
      coach_content_source.coach_workspace_id == coach_content_item.coach_workspace_id
    errors.add(:base, "content item owner does not match the source") unless allowed_owner && coach_content_source.scope == coach_content_item.scope
  end

  def digest_matches_snapshot
    errors.add(:provenance_digest, "must match the provenance snapshot") unless integrity_valid?
  end

  def immutable_record
    errors.add(:base, "draft source provenance is immutable") if has_changes_to_save?
  end

  def prevent_destroy
    errors.add(:base, "draft source provenance cannot be deleted")
    throw :abort
  end
end
