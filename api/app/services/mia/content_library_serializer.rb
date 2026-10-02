# frozen_string_literal: true

require "set"

module Mia
  class ContentLibrarySerializer
    def initialize(policy:)
      @policy = policy
    end

    def item(item)
      preload_item(item)
      editable = editable_item_ids.include?(item.id)
      approvable = reviewable_item_ids.include?(item.id)
      draft_visible = editable || approvable
      display_version = item.current_approved_version
      {
        id: item.id,
        title: draft_visible ? item.title : display_version&.title,
        scope: item.scope,
        kind: draft_visible ? item.kind : display_version&.kind,
        always_on: draft_visible ? item.draft_always_on : display_version&.always_on,
        draft_content: draft_visible ? item.draft_content : nil,
        draft_revision: draft_visible ? item.draft_revision : nil,
        draft_digest: draft_visible ? item.draft_digest : nil,
        archived: item.archived?,
        editable: editable && !item.archived?,
        approvable: approvable && !item.archived?,
        current_approved_version: display_version && item_version(display_version),
        versions: associated_records(item, :versions).sort_by { |version| -version.version_number }.map { |version| item_version(version) },
        has_unapproved_changes: draft_visible && (display_version.nil? || display_version.content_digest != item.draft_digest),
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
      preload_pack(pack)
      editable = editable_pack_ids.include?(pack.id)
      publishable = publishable_pack_ids.include?(pack.id)
      draft_visible = editable || publishable
      display_version = pack.current_published_version
      draft_entries = draft_visible ? sorted_entries(pack, :draft_entries) : []
      draft_digest = draft_visible ? CoachContentPackVersion.draft_manifest_digest_for(pack, draft_entries) : nil
      unpublished_changes = draft_visible && unpublished_changes?(display_version, draft_digest)
      item_updates = draft_visible && item_updates_available?(draft_entries)
      {
        id: pack.id,
        name: draft_visible ? pack.name : display_version&.name,
        description: draft_visible ? pack.description.to_s : display_version&.description.to_s,
        scope: pack.scope,
        pack_kind: draft_visible ? pack.pack_kind : display_version&.pack_kind,
        draft_revision: draft_visible ? pack.draft_revision : nil,
        draft_manifest_digest: draft_digest,
        archived: pack.archived?,
        editable: editable && !pack.archived?,
        publishable: publishable && !pack.archived?,
        draft_items: draft_entries.map { |entry| item_version(entry.coach_content_item_version) },
        current_published_version: display_version && pack_version(display_version),
        versions: associated_records(pack, :versions).sort_by { |version| -version.version_number }.map { |version| pack_version(version) },
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
        items: sorted_entries(version, :entries).map { |entry| item_version(entry.coach_content_item_version) }
      }
    end

    private

    attr_reader :policy

    def preload_item(item)
      return if item.association(:current_approved_version).loaded? && item.association(:versions).loaded?

      ActiveRecord::Associations::Preloader.new(
        records: [ item ],
        associations: [ :current_approved_version, :versions ]
      ).call
    end

    def preload_pack(pack)
      top_level_loaded = %i[current_published_version versions draft_entries].all? do |association_name|
        pack.association(association_name).loaded?
      end
      return if top_level_loaded

      ActiveRecord::Associations::Preloader.new(
        records: [ pack ],
        associations: {
          current_published_version: { entries: { coach_content_item_version: :source_provenance } },
          versions: { entries: { coach_content_item_version: :source_provenance } },
          draft_entries: { coach_content_item_version: [ :source_provenance, { coach_content_item: :current_approved_version } ] }
        }
      ).call
    end

    def editable_item_ids
      @editable_item_ids ||= policy.editable_items.pluck(:id).to_set
    end

    def reviewable_item_ids
      @reviewable_item_ids ||= if policy.separate_reviewer_permissions?
        policy.reviewable_items.pluck(:id).to_set
      else
        editable_item_ids
      end
    end

    def editable_pack_ids
      @editable_pack_ids ||= policy.editable_packs.pluck(:id).to_set
    end

    def publishable_pack_ids
      @publishable_pack_ids ||= if policy.separate_publisher_permissions?
        policy.publishable_packs.pluck(:id).to_set
      else
        editable_pack_ids
      end
    end

    def associated_records(record, association_name)
      association = record.association(association_name)
      association.loaded? ? association.target : record.public_send(association_name).to_a
    end

    def sorted_entries(record, association_name)
      associated_records(record, association_name).sort_by(&:position)
    end

    def unpublished_changes?(published_version, draft_digest)
      return true unless published_version

      published_digest = CoachContentPackVersion.draft_manifest_digest_for(
        published_version,
        sorted_entries(published_version, :entries)
      )
      draft_digest != published_digest
    end

    def item_updates_available?(draft_entries)
      draft_entries.any? do |entry|
        item = entry.coach_content_item_version.coach_content_item
        item.current_approved_version_id != entry.coach_content_item_version_id
      end
    end
  end
end
