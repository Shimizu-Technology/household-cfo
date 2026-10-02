# frozen_string_literal: true

module Mia
  class ContentLibraryPolicy
    def initialize(user, workspace: nil)
      @user = user
      @workspace = workspace
    end

    def visible_items
      return CoachContentItem.all if global_admin?
      return CoachContentItem.none unless workspace&.allows?(user, :view)

      CoachContentItem.where(scope: "platform").where.not(current_approved_version_id: nil)
        .or(CoachContentItem.where(scope: "coach", coach_workspace: workspace))
    end

    def editable_items
      return CoachContentItem.all if global_admin?
      return CoachContentItem.none unless workspace

      platform = user.admin? ? CoachContentItem.where(scope: "platform") : CoachContentItem.none
      coach = workspace.allows?(user, :edit) ? CoachContentItem.where(scope: "coach", coach_workspace: workspace) : CoachContentItem.none
      platform.or(coach)
    end

    def reviewable_items
      return CoachContentItem.all if global_admin?
      return CoachContentItem.none unless workspace

      platform = user.admin? ? CoachContentItem.where(scope: "platform") : CoachContentItem.none
      coach = workspace.allows?(user, :review) ? CoachContentItem.where(scope: "coach", coach_workspace: workspace) : CoachContentItem.none
      platform.or(coach)
    end

    def visible_packs
      return CoachContentPack.all if global_admin?
      return CoachContentPack.none unless workspace&.allows?(user, :view)

      CoachContentPack.where(scope: "platform").where.not(current_published_version_id: nil)
        .or(CoachContentPack.where(scope: "coach", coach_workspace: workspace))
    end

    def editable_packs
      return CoachContentPack.all if global_admin?
      return CoachContentPack.none unless workspace

      platform = user.admin? ? CoachContentPack.where(scope: "platform") : CoachContentPack.none
      coach = workspace.allows?(user, :edit) ? CoachContentPack.where(scope: "coach", coach_workspace: workspace) : CoachContentPack.none
      platform.or(coach)
    end

    def publishable_packs
      return CoachContentPack.all if global_admin?
      return CoachContentPack.none unless workspace

      platform = user.admin? ? CoachContentPack.where(scope: "platform") : CoachContentPack.none
      coach = workspace.allows?(user, :publish) ? CoachContentPack.where(scope: "coach", coach_workspace: workspace) : CoachContentPack.none
      platform.or(coach)
    end

    def visible_pack_versions
      CoachContentPackVersion.where(
        coach_content_pack_id: visible_packs.where(archived_at: nil).select(:id)
      )
    end

    def visible_sources
      visible = CoachContentSource.where.not(status: %w[uploading verifying upload_cleanup])
      return visible if global_admin?
      return CoachContentSource.none unless workspace&.allows?(user, :view)

      platform = user.admin? ? visible.where(scope: "platform") : visible.none
      coach = visible.where(scope: "coach", coach_workspace: workspace)
      coach = coach.where.not(status: "upload_cleanup_failed") unless user.admin?
      platform.or(coach)
    end

    def editable_sources
      return visible_sources if global_admin?
      return CoachContentSource.none unless workspace&.allows?(user, :edit) || user.admin?

      visible_sources
    end

    def accessible_sources
      return visible_sources if global_admin?
      return CoachContentSource.none unless workspace
      return visible_sources if user.admin? || workspace.allows?(user, :edit) || workspace.allows?(user, :review)

      CoachContentSource.none
    end

    def reviewable_sources
      return visible_sources if global_admin?
      return CoachContentSource.none unless workspace&.allows?(user, :review) || user.admin?

      visible_sources
    end

    def source_permissions(source)
      editable = source_allowed_for?(source, :edit)
      reviewable = source_allowed_for?(source, :review)
      {
        edit_candidates: editable,
        review_candidates: reviewable,
        download: editable || reviewable,
        reprocess: editable,
        delete: editable
      }
    end

    def source_collection_permissions
      {
        upload_coach: workspace.present? && (user.admin? || workspace.allows?(user, :edit)),
        upload_platform: user.admin?,
        retry_cleanup: user.admin?
      }
    end

    def can_upload_source?(scope)
      key = scope.to_s == "platform" ? :upload_platform : :upload_coach
      source_collection_permissions.fetch(key)
    end

    def separate_reviewer_permissions?
      workspace.present? && workspace.allows?(user, :review) && !workspace.allows?(user, :edit)
    end

    def separate_publisher_permissions?
      workspace.present? && workspace.allows?(user, :publish) && !workspace.allows?(user, :edit)
    end

    private

    attr_reader :user, :workspace

    def global_admin?
      user.admin? && workspace.nil?
    end

    def source_allowed_for?(source, permission)
      return true if global_admin?
      return false unless workspace
      return true if source.scope == "platform" && user.admin?

      source.scope == "coach" && source.coach_workspace_id == workspace.id && workspace.allows?(user, permission)
    end
  end
end
