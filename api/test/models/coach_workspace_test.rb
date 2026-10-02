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

  test "cohort coach roles reconcile derived workspace access across promotion demotion transfer and last removal" do
    first_owner = create_staff("coach")
    second_owner = create_staff("coach")
    staff = create_staff("coach")
    first_workspace = CoachWorkspaces::Provisioner.ensure_for!(first_owner)
    second_workspace = CoachWorkspaces::Provisioner.ensure_for!(second_owner)
    first_cohort = Cohort.create!(name: "Independent first cohort", status: "active", created_by_user: first_owner, coach_workspace: first_workspace)
    another_first_cohort = Cohort.create!(name: "Independent first backup", status: "active", created_by_user: first_owner, coach_workspace: first_workspace)
    second_cohort = Cohort.create!(name: "Independent second cohort", status: "active", created_by_user: second_owner, coach_workspace: second_workspace)

    cohort_access = staff.cohort_memberships.create!(cohort: first_cohort, role: "participant")
    assert_nil first_workspace.membership_for(staff)
    assert_nil second_workspace.membership_for(staff)

    cohort_access.update!(role: "coach")
    derived_access = first_workspace.membership_for(staff)
    assert_equal "editor", derived_access.role
    assert_predicate derived_access, :cohort_managed?

    backup_access = staff.cohort_memberships.create!(cohort: another_first_cohort, role: "coach")
    cohort_access.destroy!
    assert_equal "editor", first_workspace.membership_for(staff).role

    backup_access.update!(cohort: second_cohort)
    assert_nil first_workspace.membership_for(staff)
    assert_equal "editor", second_workspace.membership_for(staff).role

    backup_access.update!(role: "participant")
    assert_nil second_workspace.membership_for(staff)
  end

  test "changing both cohort and user reconciles every old and new access pair" do
    first_owner = create_staff("coach")
    second_owner = create_staff("coach")
    previous_staff = create_staff("coach")
    next_staff = create_staff("coach")
    first_workspace = CoachWorkspaces::Provisioner.ensure_for!(first_owner)
    second_workspace = CoachWorkspaces::Provisioner.ensure_for!(second_owner)
    first_cohort = Cohort.create!(name: "Dual transfer old", status: "active", created_by_user: first_owner, coach_workspace: first_workspace)
    second_cohort = Cohort.create!(name: "Dual transfer new", status: "active", created_by_user: second_owner, coach_workspace: second_workspace)
    membership = CohortMembership.create!(cohort: first_cohort, user: previous_staff, role: "coach")

    assert first_workspace.membership_for(previous_staff)
    membership.update!(cohort: second_cohort, user: next_staff)

    assert_nil first_workspace.reload.membership_for(previous_staff)
    assert_nil first_workspace.membership_for(next_staff)
    assert_nil second_workspace.reload.membership_for(previous_staff)
    assert_equal "editor", second_workspace.membership_for(next_staff).role
  end

  test "membership lookup uses a loaded association without querying again" do
    owner = create_staff("coach")
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    workspace.coach_workspace_memberships.load
    sql_queries = []

    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _started, _finished, _id, payload|
      sql_queries << payload[:sql] unless payload[:name] == "SCHEMA" || payload[:cached]
    end
    assert_equal owner.id, workspace.membership_for(owner).user_id
    assert_empty sql_queries
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  test "explicit workspace access is not removed with the last cohort role" do
    owner = create_staff("coach")
    staff = create_staff("coach")
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    workspace.coach_workspace_memberships.create!(user: staff, role: "reviewer")
    cohort = Cohort.create!(name: "Explicit collaborator cohort", status: "active", created_by_user: owner, coach_workspace: workspace)

    cohort_access = staff.cohort_memberships.create!(cohort: cohort, role: "coach")
    assert_equal "reviewer", workspace.membership_for(staff).role

    cohort_access.destroy!
    assert_equal "reviewer", workspace.membership_for(staff).role
    refute_predicate workspace.membership_for(staff), :cohort_managed?
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
