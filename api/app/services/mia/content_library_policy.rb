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

    def reviewable_sources
      return visible_sources if global_admin?
      return CoachContentSource.none unless workspace&.allows?(user, :review) || user.admin?

      visible_sources
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
  end
end
