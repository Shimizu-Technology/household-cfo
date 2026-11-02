# frozen_string_literal: true

require "test_helper"
require "uri"

class ApiV1WorkspaceBrandLogosControllerTest < ActionDispatch::IntegrationTest
  setup do
    @owner = create_user("coach")
    @workspace = CoachWorkspaces::Provisioner.ensure_for!(@owner)
    @configuration = @workspace.workspace_brand_configuration
    @stored = []
    @deleted = []
    @upload_result = true
    @during_upload = nil
    stored, deleted = @stored, @deleted
    test = self
    @original_upload = S3Service.method(:upload)
    @original_delete = S3Service.method(:delete)
    S3Service.define_singleton_method(:upload) do |key, data, content_type:|
      stored << { key: key, data: data, content_type: content_type }
      test.instance_variable_get(:@during_upload)&.call
      test.instance_variable_get(:@upload_result) && key
    end
    S3Service.define_singleton_method(:delete) { |key| deleted << key; true }
    https!
  end

  teardown do
    S3Service.define_singleton_method(:upload, @original_upload)
    S3Service.define_singleton_method(:delete, @original_delete)
    @files&.each(&:close!)
  end

  test "upload saves only a draft invalidates preview and keeps publication audited" do
    old_version = @configuration.current_published_version
    preview = Branding::Publisher.new(configuration: @configuration, actor: @owner).preview!(expected_draft_revision: @configuration.draft_revision)
    revision = @configuration.draft_revision
    post endpoint, params: { file: upload, draft_revision: revision }, headers: headers(@owner)
    assert_response :success
    draft = response.parsed_body.fetch("brand_configuration")
    assert_equal revision + 1, draft["draft_revision"]
    assert_nil draft["preview"]
    assert draft["preview_required"]
    url = draft.dig("draft", "logo_url")
    assert_match %r{\Ahttps://www.example.com/api/public/brand_logos/}, url
    assert_equal @owner.id, @configuration.reload.last_edited_by_user_id
    assert_equal old_version, @configuration.current_published_version
    assert_nil old_version.config["logo_url"]
    assert_equal 1, @stored.length
    assert_match %r{/branding/workspaces/#{@workspace.id}/logos/[0-9a-f-]+\.png\z}, @stored.first[:key]
    assert_equal "image/png", @stored.first[:content_type]
    assert_empty @deleted

    assert_raises(Branding::Publisher::PublicationError) do
      Branding::Publisher.new(configuration: @configuration, actor: @owner).publish!(expected_preview_digest: preview,
        expected_draft_revision: revision, expected_current_version_id: old_version.id, idempotency_key: SecureRandom.uuid)
    end
    digest = Branding::Publisher.new(configuration: @configuration, actor: @owner).preview!(expected_draft_revision: revision + 1)
    published = Branding::Publisher.new(configuration: @configuration, actor: @owner).publish!(expected_preview_digest: digest,
      expected_draft_revision: revision + 1, expected_current_version_id: old_version.id, idempotency_key: SecureRandom.uuid)
    assert_equal url, published.config["logo_url"]
    assert_equal @owner.id, @configuration.publication_events.last.actor_user_id
    assert_equal old_version.config, old_version.reload.config
  end

  test "only an authenticated workspace editor can upload" do
    post endpoint, params: { file: upload, draft_revision: 1 }
    assert_response :unauthorized
    [ "viewer", "reviewer" ].each do |role|
      user = create_user("coach")
      @workspace.coach_workspace_memberships.create!(user: user, role: role)
      post endpoint, params: { file: upload, draft_revision: 1 }, headers: headers(user)
      assert_response :not_found
    end
    outsider = create_user("coach")
    post endpoint, params: { file: upload, draft_revision: 1 }, headers: headers(outsider)
    assert_response :not_found
    participant = create_user("participant")
    post endpoint, params: { file: upload, draft_revision: 1 }, headers: headers(participant)
    assert_response :forbidden
    admin = create_user("admin")
    post endpoint, params: { file: upload, draft_revision: 1 }, headers: { "Authorization" => "Bearer test_token_#{admin.id}" }
    assert_response :not_found
    assert_empty @stored

    editor = create_user("coach")
    @workspace.coach_workspace_memberships.create!(user: editor, role: "editor")
    post endpoint, params: { file: upload, draft_revision: 1 }, headers: headers(editor)
    assert_response :success
    assert_equal editor.id, @configuration.reload.last_edited_by_user_id
  end

  test "stale missing and invalid files do not write objects or drafts" do
    [ { draft_revision: 0, file: upload }, { draft_revision: 1 },
      { draft_revision: 1, file: upload(bytes: "<svg/>") }, { draft_revision: 1, file: upload(type: "image/jpeg") } ].each do |input|
      post endpoint, params: input, headers: headers(@owner)
      assert_includes [ 409, 422 ], response.status
    end
    assert_equal 1, @configuration.reload.draft_revision
    assert_empty @stored
  end

  test "storage failure preserves draft revision and valid preview" do
    digest = Branding::Publisher.new(configuration: @configuration, actor: @owner).preview!(expected_draft_revision: 1)
    @upload_result = false
    post endpoint, params: { file: upload, draft_revision: 1 }, headers: headers(@owner)
    assert_response :service_unavailable
    assert_equal digest, @configuration.reload.preview_digest
    assert_equal 1, @configuration.draft_revision
    assert_equal @stored.map { |entry| entry[:key] }, @deleted
  end

  test "a draft changed during storage wins and only the failed upload is deleted" do
    @during_upload = -> { @configuration.update!(draft_config: @configuration.draft_config.merge("product_name" => "A newer name")) }
    post endpoint, params: { file: upload, draft_revision: 1 }, headers: headers(@owner)
    assert_response :conflict
    assert_equal "A newer name", @configuration.reload.draft_config["product_name"]
    assert_nil @configuration.draft_config["logo_url"]
    assert_equal @stored.map { |entry| entry[:key] }, @deleted
  end

  test "access revoked during storage cannot save a logo" do
    editor = create_user("coach")
    membership = @workspace.coach_workspace_memberships.create!(user: editor, role: "editor")
    @during_upload = -> { membership.update!(role: "viewer") }
    post endpoint, params: { file: upload, draft_revision: 1 }, headers: headers(editor)
    assert_response :not_found
    assert_equal 1, @configuration.reload.draft_revision
    assert_equal @stored.map { |entry| entry[:key] }, @deleted
  end

  test "public logo URL derives only a signed workspace key and redirects to a short lived private read" do
    asset_id = SecureRandom.uuid
    token = Branding::LogoAsset.token(workspace_id: @workspace.id, asset_id: asset_id)
    original = S3Service.method(:presigned_url)
    calls = []
    S3Service.define_singleton_method(:presigned_url) do |key, **options|
      calls << [ key, options ]
      "https://storage.example.test/logo.png?signature=temporary"
    end
    get "/api/public/brand_logos/#{token}"
    assert_response :redirect
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "nosniff", response.headers["X-Content-Type-Options"]
    assert_equal Branding::LogoAsset.key(workspace_id: @workspace.id, asset_id: asset_id), calls.first.first
    assert_equal :inline, calls.first.last[:disposition]
    get "/api/public/brand_logos/#{token}tampered"
    assert_response :not_found
    assert_equal 1, calls.length
  ensure
    S3Service.define_singleton_method(:presigned_url, original) if original
  end

  test "local HTTP logo URLs work without allowing arbitrary HTTP assets" do
    https! false
    host! "127.0.0.1:3204"
    post endpoint, params: { file: upload, draft_revision: 1 }, headers: headers(@owner)
    assert_response :success
    url = @configuration.reload.draft_config["logo_url"]
    assert_match %r{\Ahttp://127.0.0.1:3204/api/public/brand_logos/}, url
    assert_empty Branding::Schema.errors(@configuration.draft_config)
    assert Branding::Schema.errors(@configuration.draft_config.merge("logo_url" => "http://127.0.0.1:3204/anything.png")).any?
    assert Branding::Schema.errors(@configuration.draft_config.merge("logo_url" => "http://external.test/anything.png")).any?
  end

  private

  def endpoint = "/api/v1/admin/brand/logo"

  def headers(user)
    { "Authorization" => "Bearer test_token_#{user.id}", "X-Coach-Workspace-Id" => @workspace.id.to_s }
  end

  def create_user(role)
    User.create!(clerk_id: "test_brand_logo_#{SecureRandom.hex(8)}", email: "brand-logo-#{SecureRandom.hex(8)}@example.test",
      first_name: "Brand", last_name: "Coach", role: role, invitation_status: "accepted")
  end

  def upload(bytes: nil, type: "image/png")
    bytes ||= Branding::LogoImage::SIGNATURE + png_chunk("IHDR", [ 1, 1, 8, 6, 0, 0, 0 ].pack("NNC5")) +
      png_chunk("IDAT", Zlib::Deflate.deflate("\x00\x00\x00\x00\xff".b)) + png_chunk("IEND", "".b)
    file = Tempfile.new([ "logo", ".png" ], binmode: true)
    file.write(bytes); file.rewind
    (@files ||= []) << file
    Rack::Test::UploadedFile.new(file.path, type, true, original_filename: "../../unsafe-logo.png")
  end

  def png_chunk(type, bytes)
    [ bytes.bytesize ].pack("N") + type + bytes + [ Zlib.crc32(type + bytes) ].pack("N")
  end
end
