# frozen_string_literal: true

require "test_helper"

class CoachWorkspaceTest < ActiveSupport::TestCase
  test "provisioning creates one canonical owner workspace and coach profile" do
    coach = create_staff("coach")

    first = CoachWorkspaces::Provisioner.ensure_for!(coach)
    second = CoachWorkspaces::Provisioner.ensure_for!(coach)

    assert_equal first, second
    assert_equal "owner", first.membership_for(coach).role
    assert_equal "your coach", first.coach_profile.display_name
    assert_equal 1, first.coach_workspace_memberships.where(user: coach).count
  end

  test "workspace roles expose distinct editing reviewing and viewing permissions" do
    owner = create_staff("coach")
    editor = create_staff("coach")
    reviewer = create_staff("coach")
    viewer = create_staff("coach")
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    workspace.coach_workspace_memberships.create!(user: editor, role: "editor")
    workspace.coach_workspace_memberships.create!(user: reviewer, role: "reviewer")
    workspace.coach_workspace_memberships.create!(user: viewer, role: "viewer")

    assert workspace.allows?(owner, :manage_members)
    assert workspace.allows?(owner, :publish)
    assert workspace.allows?(owner, :assign)
    assert workspace.allows?(editor, :edit)
    refute workspace.allows?(editor, :publish)
    refute workspace.allows?(editor, :assign)
    refute workspace.allows?(editor, :review)
    assert workspace.allows?(reviewer, :review)
    assert workspace.allows?(reviewer, :publish)
    assert workspace.allows?(reviewer, :assign)
    refute workspace.allows?(reviewer, :edit)
    assert workspace.allows?(viewer, :view)
    refute workspace.allows?(viewer, :assign)
  end

  test "coach scoped records derive the creator workspace while platform records stay separate" do
    coach = create_staff("coach")
    admin = create_staff("admin")
    workspace = CoachWorkspaces::Provisioner.ensure_for!(coach)

    persona = CoachPersona.create!(
      name: "Workspace assistant",
      draft_config: Mia::PersonaSchema.default_configuration(
        assistant_name: "Workspace assistant",
        human_coach_name: "Coach"
      ),
      created_by_user: coach
    )
    item = CoachContentItem.create!(
      title: "Workspace method",
      scope: "coach",
      kind: "guidance",
      draft_content: "Ask one clear question.",
      created_by_user: coach
    )
    platform_item = CoachContentItem.create!(
      title: "Platform method",
      scope: "platform",
      kind: "guidance",
      draft_content: "Use the platform guardrail.",
      created_by_user: admin
    )

    assert_equal workspace, persona.coach_workspace
    assert_equal workspace, item.coach_workspace
    assert_nil platform_item.coach_workspace
  end

  test "coach names are unique per workspace while platform names keep their existing owner boundary" do
    owner = create_staff("coach")
    editor = create_staff("coach")
    first_admin = create_staff("admin")
    second_admin = create_staff("admin")
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    workspace.coach_workspace_memberships.create!(user: editor, role: "editor")

    CoachContentItem.create!(
      title: "Shared coaching method",
      scope: "coach",
      kind: "guidance",
      draft_content: "Owner wording.",
      created_by_user: owner,
      coach_workspace: workspace
    )
    duplicate_in_workspace = CoachContentItem.new(
      title: "shared COACHING method",
      scope: "coach",
      kind: "guidance",
      draft_content: "Editor wording.",
      created_by_user: editor,
      coach_workspace: workspace
    )
    refute duplicate_in_workspace.valid?
    assert_includes duplicate_in_workspace.errors[:title], "has already been taken"

    first_platform = CoachContentItem.create!(
      title: "Platform method",
      scope: "platform",
      kind: "guidance",
      draft_content: "First administrator wording.",
      created_by_user: first_admin
    )
    second_platform = CoachContentItem.create!(
      title: first_platform.title,
      scope: "platform",
      kind: "guidance",
      draft_content: "Second administrator wording.",
      created_by_user: second_admin
    )
    assert_predicate second_platform, :persisted?

    duplicate_for_owner = CoachContentItem.new(
      title: first_platform.title.upcase,
      scope: "platform",
      kind: "guidance",
      draft_content: "Duplicate administrator wording.",
      created_by_user: first_admin
    )
    refute duplicate_for_owner.valid?
    assert_includes duplicate_for_owner.errors[:title], "has already been taken"
  end

  private

  def create_staff(role)
    User.create!(
      clerk_id: "clerk_#{SecureRandom.hex(8)}",
      email: "#{SecureRandom.hex(8)}@example.com",
      role: role,
      invitation_status: "accepted"
    )
  end
end
