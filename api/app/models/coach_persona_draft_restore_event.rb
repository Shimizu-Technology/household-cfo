# frozen_string_literal: true

require "digest"
require "json"

class CoachPersonaDraftRestoreEvent < ApplicationRecord
  belongs_to :coach_persona
  belongs_to :source_version, class_name: "CoachPersonaVersion"
  belongs_to :actor_user, class_name: "User"

  validates :previous_draft_revision, numericality: { only_integer: true, greater_than: 0 }
  validates :restored_draft_revision, numericality: { only_integer: true, greater_than: 1 }
  validates :config_digest, :content_manifest_digest, :phrase_manifest_digest, :event_digest,
    format: { with: /\A[0-9a-f]{64}\z/ }
  validates :restored_at, presence: true
  validate :revision_sequence
  validate :source_belongs_to_persona
  validate :actor_can_edit_workspace, on: :create
  validate :snapshot_matches_source
  validate :digest_matches_snapshot
  validate :immutable_record, on: :update
  before_destroy :prevent_destroy

  def self.digest_for(value)
    record = value.respond_to?(:attributes) ? value.attributes : value.stringify_keys
    Digest::SHA256.hexdigest(JSON.generate(Mia::PhraseManifest.canonicalize({
      schema: "persona_draft_restore_event_v1",
      persona_id: record["coach_persona_id"],
      source_version_id: record["source_version_id"],
      actor_user_id: record["actor_user_id"],
      previous_draft_revision: record["previous_draft_revision"],
      restored_draft_revision: record["restored_draft_revision"],
      config_digest: record["config_digest"],
      content_manifest_digest: record["content_manifest_digest"],
      phrase_manifest_digest: record["phrase_manifest_digest"],
      content_pack_version_ids: record["content_pack_version_ids"],
      phrase_artifacts_snapshot: record["phrase_artifacts_snapshot"],
      restored_at: record["restored_at"]&.in_time_zone("UTC")&.iso8601(6)
    })).b)
  end

  def integrity_valid?
    source_belongs_to_persona? && snapshot_matches_source? && event_digest.present? &&
      ActiveSupport::SecurityUtils.secure_compare(event_digest, self.class.digest_for(self))
  end

  private

  def revision_sequence
    return if restored_draft_revision == previous_draft_revision.to_i + 1

    errors.add(:restored_draft_revision, "must immediately follow the previous draft revision")
  end

  def source_belongs_to_persona?
    source_version&.coach_persona_id == coach_persona_id
  end

  def source_belongs_to_persona
    errors.add(:source_version, "must belong to this persona") unless source_belongs_to_persona?
  end

  def actor_can_edit_workspace
    return if coach_persona&.coach_workspace&.allows?(actor_user, :edit)

    errors.add(:actor_user, "must be able to edit the persona workspace")
  end

  def snapshot_matches_source?
    source_version && config_digest == source_version.config_digest &&
      content_manifest_digest == source_version.content_manifest_digest &&
      phrase_manifest_digest == source_version.phrase_manifest_digest &&
      Array(content_pack_version_ids).map(&:to_i) == source_version.content_pack_links.order(:position).pluck(:coach_content_pack_version_id) &&
      phrase_artifacts_snapshot == Array(source_version.config["phrases"])
  end

  def snapshot_matches_source
    errors.add(:base, "draft restore snapshot must match the source version") unless snapshot_matches_source?
  end

  def digest_matches_snapshot
    return if event_digest.present? && ActiveSupport::SecurityUtils.secure_compare(event_digest, self.class.digest_for(self))

    errors.add(:event_digest, "must match the draft restore evidence")
  end

  def immutable_record
    errors.add(:base, "draft restore events are immutable") if has_changes_to_save?
  end

  def prevent_destroy
    errors.add(:base, "draft restore events cannot be deleted")
    throw :abort
  end
end
