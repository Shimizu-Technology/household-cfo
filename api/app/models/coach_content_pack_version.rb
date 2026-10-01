# frozen_string_literal: true

require "digest"

class CoachContentPackVersion < ApplicationRecord
  belongs_to :coach_content_pack, inverse_of: :versions
  belongs_to :published_by_user, class_name: "User", inverse_of: :published_coach_content_pack_versions
  has_many :entries, -> { order(:position) }, class_name: "CoachContentPackVersionEntry", dependent: :restrict_with_exception, inverse_of: :coach_content_pack_version
  has_many :item_versions, through: :entries, source: :coach_content_item_version
  has_many :persona_draft_links, class_name: "CoachPersonaDraftContentPack", dependent: :restrict_with_exception
  has_many :persona_version_links, class_name: "CoachPersonaVersionContentPack", dependent: :restrict_with_exception
  has_many :coach_content_citations, dependent: :restrict_with_exception

  validates :version_number, numericality: { only_integer: true, greater_than: 0 }, uniqueness: { scope: :coach_content_pack_id }
  validates :name, presence: true, length: { maximum: 160 }
  validates :scope, inclusion: { in: CoachContentPack::SCOPES }
  validates :pack_kind, inclusion: { in: CoachContentPack::KINDS }
  validates :content_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validate :published_record_is_immutable, on: :update
  before_destroy :prevent_destroy

  def self.digest_for(pack, entries)
    payload = {
      name: pack.name,
      description: pack.description.to_s,
      scope: pack.scope,
      pack_kind: pack.pack_kind,
      item_digests: entries.sort_by(&:position).map { |entry| entry.coach_content_item_version.content_digest }
    }
    Digest::SHA256.hexdigest(JSON.generate(payload).b)
  end

  private

  def published_record_is_immutable
    errors.add(:base, "published content pack versions are immutable") if has_changes_to_save?
  end

  def prevent_destroy
    errors.add(:base, "published content pack versions cannot be deleted")
    throw :abort
  end
end
