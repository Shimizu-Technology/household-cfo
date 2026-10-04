require "test_helper"
require_relative "../support/savings_challenge_test_support"

class ApiV1PilotPrivateFinanceTest < ActionDispatch::IntegrationTest
  include SavingsChallengeTestSupport
  setup do
    setup_savings_context
    travel_to Time.find_zone!("Pacific/Guam").local(2026, 11, 15, 12)
    with_savings_runtime { savings_enroll }
    @staff = User.create!(clerk_id: SecureRandom.uuid, email: "private-staff-#{SecureRandom.hex(8)}@example.com", role: "coach")
    @membership = @savings_household.household_memberships.create!(user: @staff, role: "coach_viewer")
  end
  teardown { travel_back }

  test "pilot household reads deny staff even with writable membership" do
    %w[coach_viewer partner owner].each do |role|
      @membership.update!(role: role)
      %w[workspace profile dashboard budget wealth document_imports plaid/items plaid/transactions spending_report].each do |path|
        get "/api/v1/#{path}", headers: { "Authorization" => "Bearer test_token_#{@staff.id}" }
        assert_response :forbidden, "#{role} #{path}"
        assert_includes response.headers["Cache-Control"], "no-store"
      end
    end
  end

  test "direct presenter cannot serialize a participant pilot workspace to staff" do
    assert_raises(ChallengePrivacy::PrivateFinanceAccess::Denied) do
      HouseholdFinance::DataPresenter.new(@savings_household, user: @staff).app_data
    end
    presenter = HouseholdFinance::DataPresenter.new(@savings_household, user: @savings_user)
    @savings_user.update!(role: "coach")
    assert_raises(ChallengePrivacy::PrivateFinanceAccess::Denied) { presenter.workspace }
  end

  test "source reads recheck actual participant and current lease before returning private data" do
    source = @savings_household.financial_document_imports.create!(uploaded_by_user: @savings_user, filename: "synthetic.pdf", content_type: "application/pdf", byte_size: 10, document_kind: "statement", status: "needs_review", s3_key: "synthetic/private.pdf")
    FinancialSourceUse.create!(household: @savings_household, participant_user: @savings_user, savings_enrollment: @savings_enrollment,
      financial_document_import: source, expires_at: 1.minute.ago, authorized_at: 1.day.ago, disclosure_version: "personal_end_plus_30_days_v1")
    get "/api/v1/document_imports/#{source.id}/source_url", headers: { "Authorization" => "Bearer test_token_#{@savings_user.id}" }
    assert_response :not_found
    get "/api/v1/document_imports/#{source.id}/source_content", headers: { "Authorization" => "Bearer test_token_#{@staff.id}" }
    assert_response :forbidden
  end
end
