# frozen_string_literal: true

module Mia
  class ContentLibraryPolicy
    def initialize(user)
      @user = user
    end

    def visible_items
      return CoachContentItem.all if user.admin?

      CoachContentItem.where(scope: "platform").where.not(current_approved_version_id: nil)
        .or(CoachContentItem.where(created_by_user_id: user.id))
    end

    def editable_items
      return CoachContentItem.all if user.admin?

      CoachContentItem.where(scope: "coach", created_by_user_id: user.id)
    end

    def visible_packs
      return CoachContentPack.all if user.admin?

      CoachContentPack.where(scope: "platform").where.not(current_published_version_id: nil)
        .or(CoachContentPack.where(created_by_user_id: user.id))
    end

    def editable_packs
      return CoachContentPack.all if user.admin?

      CoachContentPack.where(scope: "coach", created_by_user_id: user.id)
    end

    def visible_pack_versions
      CoachContentPackVersion.where(
        coach_content_pack_id: visible_packs.where(archived_at: nil).select(:id)
      )
    end

    def visible_sources
      visible = CoachContentSource.where.not(status: %w[uploading verifying upload_cleanup])
      return visible if user.admin?

      visible.where.not(status: "upload_cleanup_failed").where(scope: "coach", created_by_user_id: user.id)
    end

    def editable_sources
      visible_sources
    end

    private

    attr_reader :user
  end
end
