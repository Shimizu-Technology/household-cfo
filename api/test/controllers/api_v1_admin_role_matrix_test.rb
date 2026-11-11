# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"
require_relative "../support/savings_challenge_test_support"

# Every role against the admin-side endpoints: what each may open, and what the
# server refuses. The web's sections (AdminSections) follow the same table.
class ApiV1AdminRoleMatrixTest < ActionDispatch::IntegrationTest
  include PersonaTestHelper
  include SavingsChallengeTestSupport

  ENDPOINTS = {
    "groups list" => [ :get, ->(t) { "/api/v1/admin/cohorts" } ],
    "people list" => [ :get, ->(t) { "/api/v1/admin/users" } ],
    "coaching assistants" => [ :get, ->(t) { "/api/v1/admin/personas" } ],
    "people who need me today" => [ :get, ->(t) { "/api/v1/challenge_cohorts/#{t.cohort.id}/participants?view=daily" } ],
    "reports" => [ :get, ->(t) { "/api/v1/challenge_cohorts/#{t.cohort.id}/sponsor_exports" } ],
    "pause the challenge" => [ :post, ->(t) { "/api/v1/admin/cohorts/#{t.cohort.id}/challenge_access/pause" } ]
  }.freeze
  # who may use each endpoint
  ALLOWED = {
    "groups list" => %i[admin owner],
    "people list" => %i[admin owner],
    "coaching assistants" => %i[admin owner editor reviewer viewer],
    "people who need me today" => %i[admin owner],
    "reports" => %i[admin owner],
    "pause the challenge" => %i[admin owner]
  }.freeze

  setup do
    setup_savings_context
    @cohort = @savings_cohort
    workspace = @cohort.coach_workspace
    @people = { admin: persona_user(role: "admin"), owner: @savings_owner, participant: @savings_user }
    { editor: "editor", reviewer: "reviewer", viewer: "viewer" }.each do |name, role|
      @people[name] = persona_user(role: "coach").tap { |user| workspace.coach_workspace_memberships.create!(user: user, role: role) }
    end
    @workspace = workspace
  end

  attr_reader :cohort

  ENDPOINTS.each do |label, (verb, path)|
    test "#{label}: allowed for #{ALLOWED.fetch(label).join(', ')} and refused for everyone else" do
      @people.each do |name, user|
        headers = { "Authorization" => "Bearer test_token_#{user.id}", "Idempotency-Key" => "matrix-#{label.parameterize}-#{name}" }
        headers["X-Coach-Workspace-Id"] = @workspace.id.to_s unless name == :admin || name == :participant
        body = verb == :post ? { challenge_access: { reason: "Role matrix check" } } : nil
        send(verb, path.call(self), params: body, headers: headers, as: (:json if body))
        if ALLOWED.fetch(label).include?(name)
          assert_not_includes [ 401, 403 ], response.status, "#{name} should be allowed to use #{label} (got #{response.status})"
        else
          assert_includes [ 401, 403 ], response.status, "#{name} must be refused #{label} (got #{response.status})"
        end
      end
    end
  end
end
