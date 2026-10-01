# frozen_string_literal: true

require "digest"

class CoachContentPackVersion < ApplicationRecord
  ITEM_INTEGRITY_INCLUDES = [ :coach_content_item, {
    source_provenance: %i[coach_content_source coach_content_source_attempt coach_content_source_candidate]
  } ].freeze
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

  class << self
    def draft_manifest_digest_for(pack, entries)
      Digest::SHA256.hexdigest(JSON.generate(snapshot_payload(pack, entries)).b)
    end

    def draft_equivalent_digest(version)
      draft_manifest_digest_for(version, version.entries.includes(coach_content_item_version: ITEM_INTEGRITY_INCLUDES).order(:position))
    end

    def content_digest_for(version)
      payload = snapshot_payload(version, version.entries.includes(coach_content_item_version: ITEM_INTEGRITY_INCLUDES).order(:position))
        .merge(pack_version_id: version.id, pack_version_number: version.version_number)
      Digest::SHA256.hexdigest(JSON.generate(payload).b)
    end

    def item_identity(item_version, position:)
      identity = {
        position: position,
        item_version_id: item_version.id,
        item_id: item_version.coach_content_item_id,
        item_version_number: item_version.version_number,
        content_digest: item_version.content_digest
      }
      provenance_digest = item_version.source_provenance_digest
      identity[:source_provenance_digest] = provenance_digest if provenance_digest.present?
      identity
    end

    private

    def snapshot_payload(pack, entries)
      {
        pack_id: pack.respond_to?(:coach_content_pack_id) ? pack.coach_content_pack_id : pack.id,
        name: pack.name,
        description: pack.description.to_s,
        scope: pack.scope,
        pack_kind: pack.pack_kind,
        items: entries.sort_by(&:position).map do |entry|
          item_identity(entry.coach_content_item_version, position: entry.position)
        end
      }
    end
  end

  def sealed?
    sealed_at.present?
  end

  def seal!
    raise ArgumentError, "Published content pack version is already sealed" if sealed?
    unless entries.includes(coach_content_item_version: ITEM_INTEGRITY_INCLUDES).all? { |entry| entry.coach_content_item_version.integrity_valid? }
      raise ArgumentError, "Content pack versions cannot seal invalid approved item versions"
    end

    digest = self.class.content_digest_for(self)
    update_columns(content_digest: digest, sealed_at: Time.current, updated_at: Time.current)
    self.content_digest = digest
    self.sealed_at = Time.current if sealed_at.blank?
    self
  end

  def manifest_valid?
    return false unless sealed?

    linked_items = entries.includes(coach_content_item_version: ITEM_INTEGRITY_INCLUDES).order(:position).map(&:coach_content_item_version)
    return false unless linked_items.all?(&:integrity_valid?)

    ActiveSupport::SecurityUtils.secure_compare(content_digest, self.class.content_digest_for(self))
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
