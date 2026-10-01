# frozen_string_literal: true

module Mia
  class ContentLibrarySerializer
    def initialize(policy:)
      @policy = policy
    end

    def item(item)
      editable = policy.editable_items.where(id: item.id).exists?
      display_version = item.current_approved_version
      {
        id: item.id,
        title: editable ? item.title : display_version&.title,
        scope: item.scope,
        kind: editable ? item.kind : display_version&.kind,
        always_on: editable ? item.draft_always_on : display_version&.always_on,
        draft_content: editable ? item.draft_content : nil,
        draft_revision: editable ? item.draft_revision : nil,
        draft_digest: editable ? item.draft_digest : nil,
        archived: item.archived?,
        editable: editable && !item.archived?,
        current_approved_version: item.current_approved_version && item_version(item.current_approved_version),
        versions: item.versions.order(version_number: :desc).map { |version| item_version(version) },
        has_unapproved_changes: editable && (item.current_approved_version.nil? || item.current_approved_version.content_digest != item.draft_digest),
        updated_at: item.updated_at
      }
    end

    def item_version(version)
      {
        id: version.id,
        item_id: version.coach_content_item_id,
        title: version.title,
        kind: version.kind,
        always_on: version.always_on,
        content: version.content,
        version: version.version_number,
        digest: version.content_digest,
        approved_at: version.created_at
      }
    end

    def pack(pack)
      editable = policy.editable_packs.where(id: pack.id).exists?
      display_version = pack.current_published_version
      unpublished_changes = editable && unpublished_changes?(pack)
      item_updates = editable && item_updates_available?(pack)
      {
        id: pack.id,
        name: editable ? pack.name : display_version&.name,
        description: editable ? pack.description.to_s : display_version&.description.to_s,
        scope: pack.scope,
        pack_kind: editable ? pack.pack_kind : display_version&.pack_kind,
        draft_revision: editable ? pack.draft_revision : nil,
        draft_manifest_digest: editable ? pack.draft_manifest_digest : nil,
        archived: pack.archived?,
        editable: editable && !pack.archived?,
        draft_items: editable ? pack.draft_entries.includes(:coach_content_item_version).order(:position).map { |entry| item_version(entry.coach_content_item_version) } : [],
        current_published_version: pack.current_published_version && pack_version(pack.current_published_version),
        versions: pack.versions.order(version_number: :desc).map { |version| pack_version(version) },
        has_unpublished_changes: unpublished_changes,
        item_updates_available: item_updates,
        update_available: unpublished_changes || item_updates,
        updated_at: pack.updated_at
      }
    end

    def pack_version(version)
      {
        id: version.id,
        pack_id: version.coach_content_pack_id,
        name: version.name,
        description: version.description.to_s,
        scope: version.scope,
        pack_kind: version.pack_kind,
        version: version.version_number,
        digest: version.content_digest,
        published_at: version.created_at,
        items: version.entries.includes(:coach_content_item_version).order(:position).map { |entry| item_version(entry.coach_content_item_version) }
      }
    end

    private

    attr_reader :policy

    def unpublished_changes?(pack)
      return true unless pack.current_published_version

      pack.draft_manifest_digest != CoachContentPackVersion.draft_equivalent_digest(pack.current_published_version)
    end

    def item_updates_available?(pack)
      pack.draft_entries.includes(coach_content_item_version: :coach_content_item).any? do |entry|
        entry.coach_content_item_version.coach_content_item.current_approved_version_id != entry.coach_content_item_version_id
      end
    end
  end
end
