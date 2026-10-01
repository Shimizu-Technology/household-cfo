# frozen_string_literal: true

require "digest"

class CoachPersonaVersion < ApplicationRecord
  belongs_to :coach_persona, inverse_of: :versions
  belongs_to :published_by_user, class_name: "User", inverse_of: :published_coach_persona_versions
  belongs_to :source_version, class_name: "CoachPersonaVersion", optional: true

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
  has_many :publication_events,
    class_name: "CoachPersonaPublicationEvent",
    dependent: :restrict_with_exception,
    inverse_of: :coach_persona_version

  validates :version_number, numericality: { only_integer: true, greater_than: 0 }, uniqueness: { scope: :coach_persona_id }
  validates :config_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :content_manifest_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validate :publisher_is_staff
  validate :config_matches_schema_and_digest
  validate :source_version_belongs_to_persona
  validate :published_record_is_immutable, on: :update

  before_validation :normalize_config, on: :create
  before_destroy :prevent_destroy

  def self.content_manifest_digest_for(pack_versions)
    Digest::SHA256.hexdigest(JSON.generate(Array(pack_versions).map(&:content_digest)).b)
  end

  def publication_digest
    Digest::SHA256.hexdigest(JSON.generate({ config: config_digest, content: content_manifest_digest }).b)
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

  def source_version_belongs_to_persona
    return if source_version.nil? || source_version.coach_persona == coach_persona

    errors.add(:source_version, "must belong to the same persona")
  end

  def published_record_is_immutable
    errors.add(:base, "published persona versions are immutable") if has_changes_to_save?
  end

  def prevent_destroy
    errors.add(:base, "published persona versions cannot be deleted")
    throw :abort
  end
end
