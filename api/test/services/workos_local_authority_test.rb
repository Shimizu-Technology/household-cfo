require "test_helper"

class WorkosLocalAuthorityTest < ActiveSupport::TestCase
  test "accepted identity predicates stay fresh and exclude unbound provider placeholders" do
    user = workos_user
    assert user.invitation_accepted?
    assert User.accepted_linked_identity.exists?(user.id)
    User.find(user.id).update_columns(invitation_status: "revoked")
    refute user.invitation_accepted?
    refute User.accepted_linked_identity.exists?(user.id)
    User.find(user.id).update_columns(invitation_status: "pending")
    refute user.invitation_accepted?
    User.find(user.id).update_columns(invitation_status: "accepted")
    user.authentication_identities.load
    AuthenticationIdentity.where(user_id: user.id).delete_all
    refute user.invitation_accepted?
    user.update!(clerk_id: "workos_user_unsupported")
    refute user.linked_authentication_identity?
    refute user.invitation_accepted?
    user.update!(clerk_id: "clerk_real")
    assert user.invitation_accepted?
  end

  test "preloaded display identity snapshots avoid queries without relaxing authoritative checks" do
    user = workos_user
    user.authentication_identities.load
    queries = []
    subscriber = ->(*args) { queries << args.last[:sql] unless args.last[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      assert user.invitation_accepted?(fresh: false)
      assert user.linked_authentication_identity?(fresh: false)
    end
    assert_empty queries
    AuthenticationIdentity.where(user_id: user.id).delete_all
    assert user.invitation_accepted?(fresh: false), "Display snapshot deliberately reflects its loaded list"
    refute user.invitation_accepted?, "Authorization must query current identity even when preloaded"
    refute user.linked_authentication_identity?
    User.find(user.id).update_columns(invitation_status: "revoked")
    refute user.invitation_accepted?
  end

  test "unbound and unsaved identities cannot satisfy the loaded display predicate" do
    user = User.create!(email: "unbound@example.test", clerk_id: "workos_user_unbound", role: "participant", invitation_status: "accepted")
    user.authentication_identities.load
    user.authentication_identities.build(provider: "workos", issuer: "https://api.workos.com", subject: "user_unpersisted")
    refute user.linked_authentication_identity?(fresh: false)
    refute user.invitation_accepted?(fresh: false)
    user.update!(clerk_id: "clerk_legacy")
    assert user.invitation_accepted?(fresh: false)
  end

  test "two WorkOS owners permit handover but the final bound owner stays protected" do
    platform_admin = User.create!(email: "platform@example.test", clerk_id: "clerk_platform", role: "admin")
    first = workos_user
    second = workos_user
    workspace = CoachWorkspaces::Provisioner.ensure_for!(first)
    second_membership = workspace.coach_workspace_memberships.create!(user: second, role: "owner")
    service = CoachWorkspaces::Collaborators.new(workspace: workspace, actor: platform_admin)
    first_membership = workspace.coach_workspace_memberships.find_by!(user: first)
    service.change(id: first_membership.id, role: "reviewer", expected_role: "owner")
    assert_equal "reviewer", first_membership.reload.role
    assert_raises(CoachWorkspaces::Collaborators::Invalid) do
      service.remove(id: second_membership.id, expected_role: "owner")
    end
    assert CoachWorkspaceMembership.exists?(second_membership.id)
  end

  test "inactive revoked or unbound replacements do not satisfy the owner guard" do
    platform_admin = User.create!(email: "platform@example.test", clerk_id: "clerk_platform", role: "admin")
    owner = workos_user
    replacement = workos_user
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    workspace.coach_workspace_memberships.create!(user: replacement, role: "owner")
    membership = workspace.coach_workspace_memberships.find_by!(user: owner)
    service = CoachWorkspaces::Collaborators.new(workspace: workspace, actor: platform_admin)
    %w[pending revoked].each do |status|
      replacement.update!(invitation_status: status)
      assert_raises(CoachWorkspaces::Collaborators::Invalid) { service.remove(id: membership.id, expected_role: "owner") }
    end
    replacement.update!(invitation_status: "accepted")
    AuthenticationIdentity.where(user_id: replacement.id).delete_all
    assert_raises(CoachWorkspaces::Collaborators::Invalid) { service.remove(id: membership.id, expected_role: "owner") }
    assert CoachWorkspaceMembership.exists?(membership.id)
  end

  test "WorkOS reviewer authorization uses current identity role status and workspace membership" do
    owner = workos_user
    reviewer = workos_user
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    membership = workspace.coach_workspace_memberships.create!(user: reviewer, role: "reviewer")
    policy = Mia::PersonaRelease::ReviewAuthority
    assert_equal "reviewer", policy.current_review_role(workspace: workspace, reviewer: reviewer)
    snapshot, digest = policy.snapshot(workspace: workspace, actor: reviewer)
    assert policy.valid?(snapshot, digest)
    membership.update!(role: "viewer")
    refute policy.currently_authorized?(workspace: workspace, reviewer: reviewer)
    membership.update!(role: "reviewer")
    %w[pending revoked].each do |status|
      User.find(reviewer.id).update_columns(invitation_status: status)
      refute policy.currently_authorized?(workspace: workspace, reviewer: reviewer)
    end
    User.find(reviewer.id).update_columns(invitation_status: "accepted", role: "participant")
    refute policy.currently_authorized?(workspace: workspace, reviewer: reviewer)
    User.find(reviewer.id).update_columns(role: "coach")
    reviewer.authentication_identities.load
    AuthenticationIdentity.where(user_id: reviewer.id).delete_all
    refute policy.currently_authorized?(workspace: workspace, reviewer: reviewer)
  end

  private

  def workos_user
    id = SecureRandom.hex(8)
    user = User.create!(email: "#{id}@example.test", clerk_id: "pending_#{id}", role: "coach", invitation_status: "accepted")
    user.authentication_identities.create!(provider: "workos", issuer: "https://api.workos.com", subject: "user_#{id}")
    user
  end
end
