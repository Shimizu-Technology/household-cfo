# frozen_string_literal: true

require "digest"

class CoachContentItemVersion < ApplicationRecord
  belongs_to :coach_content_item, inverse_of: :versions
  belongs_to :approved_by_user, class_name: "User", inverse_of: :approved_coach_content_item_versions
  has_many :draft_pack_entries, class_name: "CoachContentPackDraftEntry", dependent: :restrict_with_exception
  has_many :pack_version_entries, class_name: "CoachContentPackVersionEntry", dependent: :restrict_with_exception
  has_many :coach_content_citations, dependent: :restrict_with_exception
  has_one :source_provenance, class_name: "CoachContentItemVersionProvenance", dependent: :restrict_with_exception,
    inverse_of: :coach_content_item_version

  validates :version_number, numericality: { only_integer: true, greater_than: 0 }, uniqueness: { scope: :coach_content_item_id }
  validates :title, presence: true, length: { maximum: 160 }
  validates :kind, inclusion: { in: CoachContentItem::KINDS }
  validates :content, presence: true, length: { maximum: 10_000 }
  validates :always_on, inclusion: { in: [ true, false ] }
  validates :content_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validate :digest_matches_content
  validate :content_has_bounded_bytes
  validate :approved_record_is_immutable, on: :update

  before_destroy :prevent_destroy

  def self.digest_for(title:, kind:, content:, always_on: false)
    Digest::SHA256.hexdigest(JSON.generate({ title: title.to_s.squish, kind: kind.to_s, content: content.to_s.strip, always_on: always_on == true }).b)
  end

  def content_digest_valid?
    expected = self.class.digest_for(title: title, kind: kind, content: content, always_on: always_on)
    content_digest.present? && ActiveSupport::SecurityUtils.secure_compare(content_digest, expected)
  end

  def integrity_valid?
    content_digest_valid? && (source_provenance.nil? || source_provenance.integrity_valid?(content_item: coach_content_item))
  end

  def source_provenance_digest
    source_provenance&.provenance_digest
  end

  private

  def digest_matches_content
    return if content_digest_valid?

    errors.add(:content_digest, "must match the approved content")
  end

  def approved_record_is_immutable
    errors.add(:base, "approved content versions are immutable") if has_changes_to_save?
  end

  def content_has_bounded_bytes
    errors.add(:content, "is too large (maximum is 12,000 bytes)") if content.to_s.bytesize > 12_000
  end

  def prevent_destroy
    errors.add(:base, "approved content versions cannot be deleted")
    throw :abort
  end
end
