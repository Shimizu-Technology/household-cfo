# frozen_string_literal: true

class WorkspaceBrandVersion < ApplicationRecord
  belongs_to :workspace_brand_configuration, inverse_of: :versions
  belongs_to :coach_workspace
  belongs_to :published_by_user, class_name: "User", inverse_of: :published_workspace_brand_versions
  belongs_to :source_version, class_name: "WorkspaceBrandVersion", optional: true

  has_many :derived_versions,
    class_name: "WorkspaceBrandVersion",
    foreign_key: :source_version_id,
    dependent: :restrict_with_exception,
    inverse_of: :source_version
  has_many :publication_events,
    class_name: "WorkspaceBrandPublicationEvent",
    dependent: :restrict_with_exception,
    inverse_of: :workspace_brand_version
  has_many :cohort_releases, dependent: :restrict_with_exception

  validates :version_number, numericality: { only_integer: true, greater_than: 0 }, uniqueness: { scope: :workspace_brand_configuration_id }
  validates :config_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validate :publisher_is_staff
  validate :config_matches_schema_and_digest
  validate :source_version_belongs_to_configuration
  validate :workspace_matches_configuration
  validate :published_record_is_immutable, on: :update

  before_validation :normalize_config, on: :create
  before_destroy :prevent_destroy

  private

  def normalize_config
    @config_schema_errors = Branding::Schema.errors(config)
    self.config = Branding::Schema.normalize(config) if @config_schema_errors.empty?
  end

  def publisher_is_staff
    errors.add(:published_by_user, "must be a coach or admin") unless published_by_user&.staff?
  end

  def config_matches_schema_and_digest
    schema_errors = Array(@config_schema_errors || Branding::Schema.errors(config))
    schema_errors.each { |message| errors.add(:config, message) }
    return if schema_errors.any? || config_digest == Branding::Schema.digest(config)

    errors.add(:config_digest, "must match the canonical configuration digest")
  end

  def source_version_belongs_to_configuration
    return if source_version.nil? || source_version.workspace_brand_configuration == workspace_brand_configuration

    errors.add(:source_version, "must belong to the same configuration")
  end

  def workspace_matches_configuration
    return if workspace_brand_configuration.nil? || coach_workspace_id == workspace_brand_configuration.coach_workspace_id

    errors.add(:coach_workspace, "must match the brand configuration")
  end

  def published_record_is_immutable
    errors.add(:base, "published brand versions are immutable") if has_changes_to_save?
  end

  def prevent_destroy
    errors.add(:base, "published brand versions cannot be deleted")
    throw :abort
  end
end
