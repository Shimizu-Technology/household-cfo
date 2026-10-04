require "test_helper"

class ApiV1ParticipantProgramsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @participant = user("participant")
    @coach = user("coach")
    @workspace = CoachWorkspaces::Provisioner.ensure_for!(@coach)
    @first = cohort("First private program", status: "active", starts_on: Date.new(2026, 10, 1))
    @second = cohort("Second private program", status: "enrolling")
    [ @first, @second ].each { |program| program.cohort_memberships.create!(user: @participant, role: "participant") }
    Branding::ActiveDomainRegistry.invalidate!
  end

  teardown { Branding::ActiveDomainRegistry.invalidate! }

  test "authenticated participant sees only own participant metadata and server current without finance creation" do
    other = user("participant")
    outsider = cohort("Unrelated private program")
    outsider.cohort_memberships.create!(user: other, role: "participant")
    coached = cohort("Coach membership is not a participant program")
    coached.cohort_memberships.create!(user: @participant, role: "coach")
    counts = [ Household, BudgetYear, SavingsEnrollment, CohortMembership ].map(&:count)
    get path, headers: headers
    assert_response :success
    body = response.parsed_body
    assert_equal @participant.id, body["actor_id"]
    assert_equal @first.id, body["current_cohort_id"]
    assert_equal [ @first.id, @second.id ], body["programs"].map { |record| record["id"] }
    assert_equal %w[id name status], body["current_program"].keys.sort
    body["programs"].each { |record| assert_equal %w[id name status], record.keys.sort }
    refute body["selection_unavailable"]
    assert_nil body["next_cursor"]
    refute_includes response.body, outsider.name
    refute_includes response.body, coached.name
    assert_equal counts, [ Household, BudgetYear, SavingsEnrollment, CohortMembership ].map(&:count)
    assert_includes response.headers["Cache-Control"], "no-store"
  end

  test "wrong removed or malformed selected cohort returns only owned alternatives without auto fallback" do
    [ "999999", "not-an-id", "1e3", @second.id.to_s ].each do |id|
      @second.cohort_memberships.where(user: @participant).delete_all if id == @second.id.to_s
      get path, headers: headers.merge("X-Cohort-Id" => id)
      assert_response :success
      body = response.parsed_body
      assert body["selection_unavailable"]
      assert_nil body["current_cohort_id"]
      assert_nil body["current_program"]
      assert_includes body["programs"].map { |record| record["id"] }, @first.id
    end
  end

  test "brand origin and registered hostname constrain enumeration and cross-brand current selection" do
    other_coach = user("coach")
    other_workspace = CoachWorkspaces::Provisioner.ensure_for!(other_coach)
    other_program = Cohort.create!(name: "Other brand private program", status: "active", created_by_user: other_coach, coach_workspace: other_workspace)
    other_program.cohort_memberships.create!(user: @participant, role: "participant")
    domain = "programs-#{SecureRandom.hex(5)}.example.test"
    CoachWorkspaceDomain.create!(coach_workspace: @workspace, hostname: domain, kind: "custom", status: "active", verified_at: Time.current, activated_at: Time.current, created_by_user: @coach, updated_by_user: @coach)
    Branding::ActiveDomainRegistry.invalidate!
    branded = headers.merge("Origin" => "https://#{domain}", "X-Brand-Hostname" => domain, "X-Cohort-Id" => other_program.id.to_s)
    get path, headers: branded
    assert_response :success
    assert response.parsed_body["selection_unavailable"]
    assert_equal [ @first.id, @second.id ], response.parsed_body["programs"].map { |record| record["id"] }
    refute_includes response.body, other_program.name
    get path, headers: branded.except("X-Cohort-Id")
    assert_response :success
    assert_equal @first.id, response.parsed_body["current_cohort_id"]
    get path, headers: branded.merge("X-Brand-Hostname" => "another.example.test")
    assert_response :unprocessable_entity
    refute response.parsed_body.key?("programs")
  end

  test "invalid unregistered malformed or mismatched brand never exposes a list" do
    [ { "X-Brand-Hostname" => "unknown.example.test" }, { "X-Brand-Hostname" => "https://invalid.example.test" }, { "Origin" => "https://foreign.example.test" }, { "Origin" => "https://user:password@foreign.example.test" }, { "Origin" => "null" } ].each do |brand|
      get path, headers: headers.merge(brand)
      assert_response :unprocessable_entity
      refute response.parsed_body.key?("programs")
      refute_includes response.body, @first.name
    end
  end

  test "all owned phases remain metadata-selectable without participation or money movement" do
    @first.update!(status: "archived", savings_challenge_release_hold: true)
    get path, headers: headers.merge("X-Cohort-Id" => @first.id.to_s)
    assert_response :success
    assert_equal @first.id, response.parsed_body["current_cohort_id"]
    assert_equal "archived", response.parsed_body.dig("current_program", "status")
    assert_equal 0, SavingsEnrollment.where(user: @participant).count
  end

  test "cursor pages retain every owned program and separately display current outside the first page" do
    102.times do |index|
      record = cohort("Paged private program #{index}", status: "active", starts_on: Date.new(2027, 1, 1))
      record.cohort_memberships.create!(user: @participant, role: "participant")
    end
    expected = @participant.cohort_memberships.where(role: "participant").order(:cohort_id).pluck(:cohort_id)
    seen = []
    cursor = nil
    loop do
      get path, params: cursor ? { cursor: cursor } : {}, headers: headers
      assert_response :success
      body = response.parsed_body
      assert_operator body["programs"].size, :<=, 50
      assert_equal expected.last, body["current_cohort_id"]
      assert_equal expected.last, body.dig("current_program", "id")
      ids = body["programs"].map { |record| record["id"] }
      assert ids.all? { |id| cursor.nil? || id > cursor }
      seen.concat(ids)
      cursor = body["next_cursor"]
      break if cursor.nil?
      assert_equal ids.last, cursor
    end
    assert_equal expected, seen
    assert_equal seen.uniq, seen
  end

  test "invalid cursors authentication and staff access fail closed" do
    [ "-1", "2.5", "abc", "1 OR 1=1" ].each do |cursor|
      get path, params: { cursor: cursor }, headers: headers
      assert_response :unprocessable_entity
      refute response.parsed_body.key?("programs")
    end
    get path
    assert_response :unauthorized
    get path, headers: headers(user: @coach)
    assert_response :forbidden
    refute response.parsed_body.key?("programs")
  end

  private

  def path = "/api/v1/participant_programs"
  def headers(user: @participant) = { "Authorization" => "Bearer test_token:#{user.clerk_id}:#{user.email}:Demo:Member" }

  def user(role)
    User.create!(clerk_id: "programs-#{SecureRandom.hex(8)}", email: "programs-#{SecureRandom.hex(8)}@example.test", role: role, invitation_status: "accepted")
  end

  def cohort(name, status: "enrolling", starts_on: nil)
    Cohort.create!(name: name, status: status, starts_on: starts_on, created_by_user: @coach, coach_workspace: @workspace)
  end
end
