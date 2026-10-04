# frozen_string_literal: true

require "test_helper"

class WorkspaceBrandingTest < ActiveSupport::TestCase
  test "brand authoring blocks unreadable muted and soft surfaces without invalidating sealed history" do
    config = Branding::Schema::DEFAULT_CONFIG.deep_dup
    config["colors"]["surface_muted"] = config["colors"]["text"]
    config["colors"]["primary_soft"] = config["colors"]["text"]
    assert_empty Branding::Schema.errors(config)
    authoring = Branding::Schema.authoring_errors(config)
    assert_includes authoring, "colors.text must have at least 4.5:1 contrast on colors.surface_muted"
    assert_includes authoring, "colors.text must have at least 4.5:1 contrast on colors.primary_soft"
    assert_empty Branding::Schema.authoring_errors(Branding::Schema::DEFAULT_CONFIG)
  end

  test "default and neutral fallback brands satisfy the controlled schema" do
    assert_empty Branding::Schema.errors(Branding::Schema::DEFAULT_CONFIG)
    assert_empty Branding::Schema.errors(Branding::Schema::SAFE_DEFAULT_CONFIG)
    assert_equal Branding::Schema::DEFAULT_CONFIG, Branding::Schema.normalize(Branding::Schema::DEFAULT_CONFIG)
  end

  test "schema rejects persona identity arbitrary fields unsafe assets and inaccessible colors" do
    config = Branding::Schema::DEFAULT_CONFIG.deep_dup
    config["agent_name"] = "A duplicated persona name"
    config["logo_url"] = "http://tracker.example/logo.svg"
    config["colors"]["text"] = "#ffffff"

    errors = Branding::Schema.errors(config)
    assert_includes errors, "must contain only supported brand fields"
    assert_includes errors, "logo_url must be an HTTPS URL without credentials or a fragment"
    assert_includes errors, "colors.text must have at least 4.5:1 contrast on colors.background"
  end

  test "schema keeps primary text and primary controls readable in every interactive state" do
    light_primary = Branding::Schema::DEFAULT_CONFIG.deep_dup
    light_primary["colors"]["primary"] = "#fffdf8"
    light_primary_errors = Branding::Schema.errors(light_primary)
    assert_includes light_primary_errors, "colors.on_primary must have at least 4.5:1 contrast on colors.primary"
    assert_includes light_primary_errors, "colors.primary must have at least 4.5:1 contrast on colors.background"
    assert_includes light_primary_errors, "colors.primary must have at least 4.5:1 contrast on colors.surface"

    light_hover = Branding::Schema::DEFAULT_CONFIG.deep_dup
    light_hover["colors"]["primary_hover"] = "#fffdf8"
    assert_includes Branding::Schema.errors(light_hover), "colors.on_primary must have at least 4.5:1 contrast on colors.primary_hover"

    low_surface_contrast = Branding::Schema::DEFAULT_CONFIG.deep_dup
    low_surface_contrast["colors"]["text_muted"] = low_surface_contrast["colors"]["surface"]
    low_surface_contrast["colors"]["focus"] = low_surface_contrast["colors"]["surface"]
    surface_errors = Branding::Schema.errors(low_surface_contrast)
    assert_includes surface_errors, "colors.text_muted must have at least 4.5:1 contrast on colors.surface"
    assert_includes surface_errors, "colors.focus must have at least 3:1 contrast on colors.surface"
  end

  test "workspace provisioning creates one published default brand with immutable versions" do
    owner = create_staff
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    configuration = workspace.workspace_brand_configuration

    assert_equal Branding::Schema::DEFAULT_CONFIG, configuration.draft_config
    assert_equal 1, configuration.versions.count
    assert_equal configuration.versions.first, configuration.current_published_version
    assert_equal 1, configuration.publication_events.count
    assert_equal "publish", configuration.publication_events.first.event_type

    assert_raises(ActiveRecord::StatementInvalid) do
      WorkspaceBrandVersion.where(id: configuration.current_published_version_id).update_all(version_number: 99)
    end
  end

  test "workspace brand publication evidence cannot be deleted" do
    workspace = CoachWorkspaces::Provisioner.ensure_for!(create_staff)

    assert_raises(ActiveRecord::StatementInvalid) do
      WorkspaceBrandPublicationEvent.where(id: workspace.workspace_brand_configuration.publication_events.first.id).delete_all
    end
  end

  test "database rejects a brand version bound to another workspace" do
    first = CoachWorkspaces::Provisioner.ensure_for!(create_staff)
    second = CoachWorkspaces::Provisioner.ensure_for!(create_staff)
    configuration = first.workspace_brand_configuration

    assert_raises(ActiveRecord::InvalidForeignKey) do
      WorkspaceBrandVersion.insert!({
        workspace_brand_configuration_id: configuration.id,
        coach_workspace_id: second.id,
        version_number: 2,
        config: Branding::Schema::DEFAULT_CONFIG,
        config_digest: Branding::Schema.digest(Branding::Schema::DEFAULT_CONFIG),
        published_by_user_id: first.created_by_user_id,
        created_at: Time.current,
        updated_at: Time.current
      })
    end
  end

  test "public resolver uses only exact active verified domains" do
    owner = create_staff
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    now = Time.current
    domain = workspace.coach_workspace_domains.create!(
      hostname: "Money.Coach-Example.com",
      kind: "custom",
      status: "active",
      is_primary: true,
      verified_at: now,
      activated_at: now,
      created_by_user: owner,
      updated_by_user: owner
    )

    assert_equal "money.coach-example.com", domain.hostname
    resolved = Branding::PublicResolver.new(hostname: "money.coach-example.com").call
    assert resolved.available
    assert_equal workspace, resolved.workspace
    assert_equal "published_workspace_brand", resolved.source

    [ "coach-example.com", "evil-money.coach-example.com", "money.coach-example.com.", "money.coach-example.com:443" ].each do |hostname|
      result = Branding::PublicResolver.new(hostname: hostname).call
      refute result.available, hostname
      assert_equal Branding::Schema::SAFE_DEFAULT_CONFIG, result.config
    end

    invalid_config = Branding::Schema::DEFAULT_CONFIG.deep_dup
    invalid_config["colors"]["primary_hover"] = invalid_config["colors"]["on_primary"]
    WorkspaceBrandVersion.insert!({
      workspace_brand_configuration_id: workspace.workspace_brand_configuration.id,
      coach_workspace_id: workspace.id,
      version_number: 2,
      config: invalid_config,
      config_digest: Branding::Schema.digest(invalid_config),
      published_by_user_id: owner.id,
      created_at: Time.current,
      updated_at: Time.current
    })
    invalid_version_id = WorkspaceBrandVersion.where(
      workspace_brand_configuration_id: workspace.workspace_brand_configuration.id,
      version_number: 2
    ).pick(:id)
    workspace.workspace_brand_configuration.update_columns(current_published_version_id: invalid_version_id, updated_at: Time.current)

    invalid_result = Branding::PublicResolver.new(hostname: domain.hostname).call
    refute invalid_result.available
    assert_equal Branding::Schema::SAFE_DEFAULT_CONFIG, invalid_result.config
  end

  test "unverified disabled and duplicate primary domains cannot become participant entry points" do
    owner = create_staff
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    pending = workspace.coach_workspace_domains.new(
      hostname: "pending.example.com",
      kind: "custom",
      status: "active",
      is_primary: true,
      created_by_user: owner,
      updated_by_user: owner,
      activated_at: Time.current
    )
    refute pending.valid?
    assert_includes pending.errors[:verified_at], "is required for a verified domain"

    now = Time.current
    workspace.coach_workspace_domains.create!(
      hostname: "first.example.com", kind: "custom", status: "active", is_primary: true,
      verified_at: now, activated_at: now, created_by_user: owner, updated_by_user: owner
    )
    assert_raises(ActiveRecord::RecordNotUnique) do
      CoachWorkspaceDomain.insert!({
        coach_workspace_id: workspace.id,
        hostname: "second.example.com",
        kind: "custom",
        status: "active",
        is_primary: true,
        verified_at: now,
        activated_at: now,
        created_by_user_id: owner.id,
        updated_by_user_id: owner.id,
        lock_version: 0,
        created_at: now,
        updated_at: now
      })
    end
  end

  test "verified domain identity cannot change through models or direct SQL" do
    owner = create_staff
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    now = Time.current
    domain = workspace.coach_workspace_domains.create!(
      hostname: "verified.example.com", kind: "custom", status: "active", is_primary: true,
      verification_requested_at: now, verified_at: now, activated_at: now,
      created_by_user: owner, updated_by_user: owner
    )

    domain.hostname = "renamed.example.com"
    refute domain.valid?
    assert_includes domain.errors[:base], "hostname and kind cannot change after domain verification begins"

    assert_raises(ActiveRecord::StatementInvalid) do
      CoachWorkspaceDomain.where(id: domain.id).update_all(hostname: "sql-renamed.example.com")
    end
  end

  test "a current owner can update a domain after its creator loses edit permission" do
    creator = create_staff
    successor = create_staff
    workspace = CoachWorkspaces::Provisioner.ensure_for!(creator)
    workspace.coach_workspace_memberships.create!(user: successor, role: "owner")
    now = Time.current
    domain = workspace.coach_workspace_domains.create!(
      hostname: "handoff.example.com", kind: "custom", status: "active", is_primary: true,
      verified_at: now, activated_at: now, created_by_user: creator, updated_by_user: creator
    )
    workspace.coach_workspace_memberships.find_by!(user: creator).update!(role: "viewer")

    domain.update!(
      status: "disabled",
      is_primary: false,
      disabled_at: Time.current,
      updated_by_user: successor
    )
    assert_equal "disabled", domain.reload.status
    assert_equal successor, domain.updated_by_user
  end

  test "active domain registry invalidates after a domain is disabled" do
    owner = create_staff
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    now = Time.current
    domain = workspace.coach_workspace_domains.create!(
      hostname: "cached.example.com", kind: "custom", status: "active", is_primary: true,
      verified_at: now, activated_at: now, created_by_user: owner, updated_by_user: owner
    )

    assert_equal workspace.id, Branding::ActiveDomainRegistry.workspace_id_for(domain.hostname)
    domain.update!(status: "disabled", is_primary: false, disabled_at: Time.current, updated_by_user: owner)
    assert_nil Branding::ActiveDomainRegistry.workspace_id_for(domain.hostname)
  end

  private

  def create_staff
    User.create!(
      clerk_id: "brand_model_#{SecureRandom.hex(7)}",
      email: "brand-model-#{SecureRandom.hex(7)}@example.com",
      role: "coach",
      invitation_status: "accepted"
    )
  end
end
