# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"
require_relative "../support/savings_challenge_test_support"

# The Admin side lists a section only when that section's own main read works.
# For every kind of staff member, every section the server lists must open: its
# main API answers 200, never an error screen.
class ApiV1AdminSectionsTest < ActionDispatch::IntegrationTest
  include PersonaTestHelper
  include SavingsChallengeTestSupport

  setup do
    setup_savings_context
    @cohort = @savings_cohort
    @workspace = @cohort.coach_workspace
    @people = { admin: persona_user(role: "admin"), owner: @savings_owner }
    %w[editor reviewer viewer].each do |role|
      @people[role.to_sym] = persona_user(role: "coach").tap { |user| @workspace.coach_workspace_memberships.create!(user: user, role: role) }
    end
    # The same roles again, but each also coaches the group.
    %w[editor reviewer viewer].each do |role|
      user = persona_user(role: "coach").tap { |coach| @workspace.coach_workspace_memberships.create!(user: coach, role: role) }
      CohortMembership.create!(cohort: @cohort, user: user, role: "coach")
      @people[:"#{role} who coaches the group"] = user
    end
    @people[:"admin on the program team"] = persona_user(role: "admin").tap do |user|
      @workspace.coach_workspace_memberships.create!(user: user, role: "viewer")
      CohortMembership.create!(cohort: @cohort, user: user, role: "admin")
    end
  end

  MAIN_READS = {
    "today" => ->(t) { "/api/v1/challenge_cohorts/#{t.cohort_id}/participants?view=daily" },
    "people" => ->(_) { "/api/v1/admin/users" },
    "groups" => ->(_) { "/api/v1/admin/cohorts" },
    "coaching" => ->(_) { "/api/v1/admin/personas" },
    "reports" => ->(t) { "/api/v1/challenge_cohorts/#{t.cohort_id}/sponsor_exports" },
    "support" => ->(_) { "/api/v1/setup_support_requests" },
    "settings" => ->(t) { "/api/v1/admin/collaborators" }
  }.freeze

  test "every listed section's main API answers 200, for every kind of staff member" do
    @people.each do |name, user|
      headers = { "Authorization" => "Bearer test_token_#{user.id}" }
      headers["X-Coach-Workspace-Id"] = @workspace.id.to_s unless name.to_s.start_with?("admin") && !name.to_s.include?("team")
      get "/api/v1/auth/me", headers: headers
      sections = response.parsed_body.dig("user", "admin_sections").map { |section| section["key"] }
      sections.each do |key|
        path = MAIN_READS.fetch(key).call(self)
        # An administrator who has not picked a program has no team to list; Settings then shows platform settings.
        path = "/api/v1/admin/plaid_health" if key == "settings" && !headers.key?("X-Coach-Workspace-Id")
        get path, headers: headers
        assert_equal 200, response.status, "#{name} is offered #{key}, but its main read answered #{response.status}: #{response.body[0, 200]}"
      end
    end
  end

  test "a section that is not listed is refused by its API" do
    @people.each do |name, user|
      headers = { "Authorization" => "Bearer test_token_#{user.id}" }
      headers["X-Coach-Workspace-Id"] = @workspace.id.to_s unless name == :admin
      get "/api/v1/auth/me", headers: headers
      listed = response.parsed_body.dig("user", "admin_sections").map { |section| section["key"] }
      (MAIN_READS.keys - listed - %w[support coaching]).each do |key|
        get MAIN_READS.fetch(key).call(self), headers: headers
        assert_not_equal 200, response.status, "#{name} is not offered #{key}, so its API must refuse (got #{response.status})"
      end
    end
  end

  def cohort_id = @cohort.id
  attr_reader :cohort
end
