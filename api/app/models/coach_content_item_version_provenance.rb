# frozen_string_literal: true

require "digest"

class CoachContentItemVersionProvenance < ApplicationRecord
  belongs_to :coach_content_item_version, inverse_of: :source_provenance
  belongs_to :coach_content_source
  belongs_to :coach_content_source_attempt
  belongs_to :coach_content_source_candidate
  belongs_to :accepted_by_user, class_name: "User"

  validates :source_filename, :source_content_type, :attempt_provider, :attempt_model,
    :attempt_prompt_version, :attempt_schema_version, presence: true
  validates :source_byte_size, numericality: { only_integer: true, greater_than: 0 }
  validates :source_checksum_sha256, :candidate_content_digest, :candidate_original_proposal_digest, :evidence_excerpt_digest,
    :approved_content_digest, :provenance_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :candidate_revision, numericality: { only_integer: true, greater_than: 0 }
  validates :candidate_review_action, inclusion: { in: %w[accepted] }
  validates :accepted_at, presence: true
  validate :linked_records_match
  validate :digest_matches_snapshot
  validate :immutable_record, on: :update
  before_destroy :prevent_destroy

  class << self
    def create_from_draft!(draft:, version:)
      attributes = draft.attributes_for_version.merge(
        coach_content_item_version: version,
        approved_content_digest: version.content_digest
      )
      record = new(attributes)
      record.provenance_digest = digest_for(record.send(:attributes_for_digest))
      record.save!
      record
    end

    def digest_for(attributes)
      Digest::SHA256.hexdigest(JSON.generate(snapshot(attributes)).b)
    end

    def snapshot(attributes)
      CoachContentItemDraftProvenance.snapshot(attributes).merge(
        item_version_id: record_id(attributes, :coach_content_item_version, :coach_content_item_version_id),
        item_version_number: attributes[:coach_content_item_version]&.version_number || attributes[:item_version_number],
        approved_content_digest: attributes[:approved_content_digest]
      )
    end

    private

    def record_id(attributes, association, foreign_key)
      attributes[foreign_key] || attributes[association]&.id
    end
  end

  def integrity_valid?(content_item: nil)
    return false unless coach_content_item_version&.content_digest == approved_content_digest

    expected = self.class.digest_for(attributes_for_digest)
    provenance_digest.present? && ActiveSupport::SecurityUtils.secure_compare(provenance_digest, expected) && linked_identity_valid?(content_item: content_item)
  end

  private

  def attributes_for_digest
    attributes.symbolize_keys.merge(coach_content_item_version: coach_content_item_version)
  end

  def linked_identity_valid?(content_item: nil)
    source = coach_content_source
    attempt = coach_content_source_attempt
    candidate = coach_content_source_candidate
    item = content_item || coach_content_item_version&.coach_content_item
    return false unless source && attempt && candidate && item

    item.created_by_user_id == source.created_by_user_id && item.coach_workspace_id == source.coach_workspace_id && item.scope == source.scope &&
      phrase_content_matches_candidate?(coach_content_item_version, candidate) &&
      candidate.status == candidate_review_action && candidate_review_action == "accepted" && candidate.accepted_content_item_id == item.id &&
      source_filename == CoachContentItemDraftProvenance.provenance_filename_for(source.filename) &&
      source_content_type == source.content_type && source_byte_size == source.byte_size && source_checksum_sha256 == source.checksum_sha256 &&
      attempt.coach_content_source_id == source.id && attempt_provider == attempt.provider && attempt_model == attempt.model &&
      attempt_prompt_version == attempt.prompt_version && attempt_schema_version == attempt.schema_version &&
      candidate.coach_content_source_id == source.id && candidate.coach_content_source_attempt_id == attempt.id &&
      candidate_original_proposal_digest == candidate.original_proposal_digest && candidate_revision == candidate.revision &&
      accepted_by_user_id == candidate.reviewed_by_user_id && accepted_at == candidate.reviewed_at &&
      candidate_content_digest == candidate.content_digest && candidate.content_digest == candidate.review_digest &&
      evidence_locator == candidate.evidence_locator && evidence_excerpt_digest == candidate.evidence_locator["excerpt_digest"]
  end

  def linked_records_match
    return if coach_content_source.nil? || coach_content_source_attempt.nil? || coach_content_source_candidate.nil? || coach_content_item_version.nil?

    errors.add(:base, "source attempt does not belong to the source") unless coach_content_source_attempt.coach_content_source_id == coach_content_source_id
    errors.add(:base, "candidate does not belong to the source attempt") unless coach_content_source_candidate.coach_content_source_attempt_id == coach_content_source_attempt_id
    errors.add(:base, "candidate does not belong to the source") unless coach_content_source_candidate.coach_content_source_id == coach_content_source_id
    item = coach_content_item_version.coach_content_item
    valid_owner = item.created_by_user_id == coach_content_source.created_by_user_id &&
      item.coach_workspace_id == coach_content_source.coach_workspace_id
    errors.add(:base, "approved content owner does not match the source") unless valid_owner && item.scope == coach_content_source.scope
    errors.add(:base, "approved phrase wording does not match the reviewed candidate") unless phrase_content_matches_candidate?(coach_content_item_version, coach_content_source_candidate)
  end

  def phrase_content_matches_candidate?(version, candidate)
    candidate.kind != "phrase" || (
      version.kind == "phrase" && version.title == candidate.title && version.content == candidate.content && version.always_on == false
    )
  end

  def digest_matches_snapshot
    errors.add(:provenance_digest, "must match the approved provenance snapshot") unless integrity_valid?
  end

  def immutable_record
    errors.add(:base, "approved source provenance is immutable") if has_changes_to_save?
  end

  def prevent_destroy
    errors.add(:base, "approved source provenance cannot be deleted")
    throw :abort
  end
end
