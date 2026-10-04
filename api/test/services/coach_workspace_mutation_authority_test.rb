# frozen_string_literal: true

require "test_helper"

class CoachWorkspaceMutationAuthorityTest < ActiveSupport::TestCase
  %w[preview publish restore].each do |action|
    test "cached global admin cannot #{action} after revocation" do
      admin = user("admin")
      workspace = CoachWorkspaces::Provisioner.ensure_for!(admin)
      configuration = workspace.workspace_brand_configuration
      publisher = Branding::Publisher.new(configuration: configuration, actor: admin)
      digest = publisher.preview!(expected_draft_revision: configuration.draft_revision)
      version = configuration.current_published_version
      User.find(admin.id).update!(invitation_status: "revoked")

      assert_no_difference [ "WorkspaceBrandVersion.count", "WorkspaceBrandPublicationEvent.count" ] do
        if action == "restore"
          assert_raises(Branding::Rollback::RollbackError) do
            Branding::Rollback.new(configuration: configuration, target_version: version, actor: admin).call(
              expected_draft_revision: configuration.draft_revision, expected_current_version_id: version.id, idempotency_key: SecureRandom.uuid)
          end
        elsif action == "preview"
          assert_raises(Branding::Publisher::PublicationError) { publisher.preview!(expected_draft_revision: configuration.draft_revision) }
        else
          assert_raises(Branding::Publisher::PublicationError) do
            publisher.publish!(expected_preview_digest: digest, expected_draft_revision: configuration.draft_revision,
              expected_current_version_id: version.id, idempotency_key: SecureRandom.uuid)
          end
        end
      end
    end
  end

  test "cached workspace memberships cannot grant mutation rights after demotion" do
    owner = user("coach")
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    workspace.coach_workspace_memberships.load
    CoachWorkspaceMembership.find_by!(coach_workspace: workspace, user: owner).update!(role: "viewer")
    assert_raises(ActiveRecord::RecordNotFound) do
      CoachWorkspaces::MutationAuthority.new(workspace: workspace, actor: owner, permissions: :manage_members).call { flunk "Unauthorized mutation ran" }
    end
    assert_raises(ActiveRecord::RecordNotFound) do
      CoachWorkspaces::Collaborators.new(workspace: workspace, actor: owner).add(email: "late@example.test", role: "editor")
    end
    assert_nil User.find_by(email: "late@example.test")
  end

  private

  def user(role)
    User.create!(clerk_id: "mutation-#{SecureRandom.uuid}", email: "#{SecureRandom.hex(8)}@example.test", role: role)
  end
end
