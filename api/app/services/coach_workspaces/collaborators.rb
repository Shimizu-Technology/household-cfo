# frozen_string_literal: true

module CoachWorkspaces
  class Collaborators
    class Conflict < StandardError; end
    class Invalid < StandardError; end

    def initialize(workspace:, actor:)
      @workspace = workspace
      @actor = actor
    end

    def list
      authorize!
      {
        workspace_id: workspace.id,
        permissions: { manage: true },
        members: workspace.coach_workspace_memberships.includes(:user).order(:id).map { |membership| serialize(membership) },
        sign_in_url: sign_in_url
      }
    end

    def add(email:, role:)
      validate_role!(role)
      normalized_email = email.to_s.strip.downcase
      unless normalized_email.length <= 254 && normalized_email.match?(URI::MailTo::EMAIL_REGEXP)
        raise Invalid, "Enter a valid collaborator email address."
      end

      with_authorized_workspace(subject_ids: -> { User.where("LOWER(email) = ?", normalized_email).pluck(:id) }) do |users|
        user = users.values.find { |account| account.email.to_s.downcase == normalized_email }
        raise Invalid, "This account cannot be added as a collaborator. Ask a platform administrator for help." if user && (!user.staff? || user.revoked?)
        new_user = user.nil?
        user ||= User.create!(email: normalized_email, clerk_id: "pending_#{SecureRandom.uuid}", role: "coach",
          invitation_status: "pending", invited_at: Time.current, invited_by_user: actor)
        membership = workspace.coach_workspace_memberships.find_by(user: user)
        if membership
          raise Conflict, "This collaborator already has access. Change their role in the list below." if membership.role != role
          if membership.cohort_managed?
            membership.update!(cohort_managed: false)
            record_event!(user, "added", before_role: role, after_role: role)
          end
          next { member: serialize(membership), new_user: false, added: false }
        end
        membership = workspace.coach_workspace_memberships.create!(user: user, role: role, cohort_managed: false)
        record_event!(user, "added", after_role: role)
        { member: serialize(membership), user: user, new_user: new_user, added: true }
      end
    rescue ActiveRecord::RecordNotUnique
      raise Conflict, "This account changed while it was being added. Refresh and try again."
    end

    def change(id:, role:, expected_role:)
      validate_role!(role)
      with_authorized_workspace(subject_ids: -> { [ workspace.coach_workspace_memberships.find(id).user_id ] }) do |users|
        membership = workspace.coach_workspace_memberships.lock.find(id)
        membership.user = users.fetch(membership.user_id)
        validate_current_role!(membership, expected_role)
        protect_access!(membership, next_role: role)
        before_role = membership.role
        membership.update!(role: role, cohort_managed: false)
        record_event!(membership.user, "role_changed", before_role: before_role, after_role: role) if before_role != role
        serialize(membership)
      end
    end

    def remove(id:, expected_role:)
      with_authorized_workspace(subject_ids: -> { [ workspace.coach_workspace_memberships.find(id).user_id ] }) do |users|
        membership = workspace.coach_workspace_memberships.lock.find(id)
        membership.user = users.fetch(membership.user_id)
        validate_current_role!(membership, expected_role)
        protect_access!(membership, next_role: nil)
        user = membership.user
        # Reconciliation must not recreate editor access from a coached cohort.
        membership.update!(cohort_managed: false)
        # Explicit workspace removal already supplies reconciliation. Calling
        # destroy callbacks here would acquire advisory locks after membership
        # locks, opposite the cohort reconciliation lock order.
        CohortMembership.joins(:cohort).where(user: user, role: %w[coach admin], cohorts: { coach_workspace_id: workspace.id }).delete_all
        before_role = membership.role
        membership.destroy!
        record_event!(user, "removed", before_role: before_role)
        { platform_admin: user.admin? }
      end
    end

    def sign_in_url
      domain = workspace.coach_workspace_domains.active.order(is_primary: :desc, id: :asc).first
      return "https://#{domain.hostname}" if domain

      configured = ENV["FRONTEND_URL"].presence || ENV["FRONTEND_URLS"].to_s.split(",").first&.strip
      uri = URI.parse(configured.to_s)
      return nil unless uri.host && uri.userinfo.nil? && uri.fragment.nil?
      return configured if uri.scheme == "https"
      return configured if !Rails.env.production? && uri.scheme == "http" && %w[localhost 127.0.0.1].include?(uri.host)

      nil
    rescue URI::InvalidURIError
      nil
    end

    private

    attr_reader :workspace, :actor

    def with_authorized_workspace(subject_ids: nil)
      MutationAuthority.new(workspace: workspace, actor: actor, permissions: :manage_members, subject_ids: subject_ids).call do |persisted_actor, users|
        @actor = persisted_actor
        yield users
      end
    end

    def authorize!
      persisted = User.find_by(id: actor.id)
      permitted = persisted&.invitation_accepted? && (persisted.admin? || (persisted.coach? &&
        workspace.coach_workspace_memberships.where(user_id: persisted.id, role: "owner").exists?))
      raise ActiveRecord::RecordNotFound unless permitted
    end

    def validate_role!(role)
      raise Invalid, "Choose owner, editor, reviewer, or viewer." unless CoachWorkspaceMembership::ROLES.include?(role)
    end

    def validate_current_role!(membership, expected_role)
      raise Conflict, "This collaborator changed in another session. Refresh before trying again." unless expected_role == membership.role
    end

    def protect_access!(membership, next_role:)
      if membership.user_id == actor.id && (next_role.nil? || (membership.role == "owner" && next_role != "owner"))
        raise Invalid, "You cannot remove or reduce your own owner access. Ask another owner or a platform administrator."
      end
      return unless membership.role == "owner" && next_role != "owner" && membership.user.invitation_accepted?

      other_owners = workspace.coach_workspace_memberships.joins(:user).where(role: "owner", users: { role: %w[coach admin] })
        .merge(User.accepted_linked_identity).where.not(id: membership.id)
      raise Invalid, "Add another active owner before removing or reducing this owner's access." unless other_owners.exists?
    end

    def serialize(membership)
      user = membership.user
      {
        id: membership.id, user_id: user.id, email: user.email, full_name: user.full_name,
        role: membership.role, status: user.revoked? ? "revoked" : user.invitation_accepted? ? "accepted" : "pending",
        platform_admin: user.admin?, is_self: user.id == actor.id, cohort_managed: membership.cohort_managed?
      }
    end

    def record_event!(user, type, before_role: nil, after_role: nil)
      CoachWorkspaceMembershipEvent.create!(coach_workspace: workspace, actor_user: actor, subject_user: user,
        event_type: type, before_role: before_role, after_role: after_role)
    end
  end
end
