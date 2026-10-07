require "test_helper"
require_relative "../support/workos_auth_test_support"

class EnterpriseReconciliationRequestsControllerTest < ActionController::TestCase
  tests Api::V1::EnterpriseOrganizationsController
  include WorkosAuthTestSupport
  include ActiveJob::TestHelper

  setup do
    @routes = ActionDispatch::Routing::RouteSet.new
    @routes.draw { post "/enterprise_organizations/:id/reconcile", to: "api/v1/enterprise_organizations#reconcile" }
    key = SecureRandom.hex(6)
    @admin = User.create!(clerk_id: "admin_#{key}", email: "admin_#{key}@local.test", role: "admin")
    @admin.authentication_identities.create!(provider: "workos", issuer: "https://api.workos.com/user_management/client_cfo", subject: "user_admin")
    workspace = CoachWorkspaces::Provisioner.ensure_for!(@admin)
    @organization = EnterpriseOrganization.create!(name: "Bank", workos_organization_id: "org_#{key}", coach_workspace: workspace)
  end

  test "repeated requests are reserved once before a queued reconciliation finishes" do
    signed_in do
      assert_enqueued_jobs 1, only: EnterpriseReconciliationJob do
        post :reconcile, params: { id: @organization.id }
        assert_response :accepted
        assert_equal true, JSON.parse(response.body)["queued"]
        post :reconcile, params: { id: @organization.id }
        assert_response :accepted
        assert_equal false, JSON.parse(response.body)["queued"]
      end
    end
    assert_equal 1, @organization.enterprise_audit_events.where(action: "reconciliation.requested").count
  end

  test "recent completed reconciliation avoids another full snapshot and audit" do
    @organization.update!(last_reconciled_at: Time.current)
    signed_in do
      assert_no_enqueued_jobs only: EnterpriseReconciliationJob do
        post :reconcile, params: { id: @organization.id }
        assert_response :accepted
        assert_equal false, JSON.parse(response.body)["queued"]
      end
    end
    assert_empty @organization.enterprise_audit_events
  end

  test "old request and old completion permit a bounded retry" do
    @organization.update!(last_reconciled_at: 2.minutes.ago)
    @organization.enterprise_audit_events.create!(action: "reconciliation.requested", created_at: 2.minutes.ago)
    signed_in do
      assert_enqueued_jobs 1, only: EnterpriseReconciliationJob do
        post :reconcile, params: { id: @organization.id }
        assert_equal true, JSON.parse(response.body)["queued"]
      end
    end
  end

  test "queue outage does not leave a throttle audit blocking the retry" do
    signed_in do
      stub_method(EnterpriseReconciliationJob, :perform_later, ->(*) { raise Enterprise::Client::Unavailable, "Queue unavailable" }) do
        post :reconcile, params: { id: @organization.id }
        assert_response :service_unavailable
      end
    end
    assert_empty @organization.enterprise_audit_events
  end

  test "an adapter rejected enqueue does not reserve the organization" do
    signed_in do
      stub_method(EnterpriseReconciliationJob, :perform_later, ->(*) { false }) do
        post :reconcile, params: { id: @organization.id }
        assert_response :service_unavailable
      end
    end
    assert_empty @organization.enterprise_audit_events
  end

  test "redundant queued manual jobs skip a recent completion without delaying notification processing" do
    @organization.update!(last_reconciled_at: Time.current)
    called = []
    stub_method(Enterprise::Reconciliation, :call, ->(organization, **_options) { called << organization.id }) do
      EnterpriseReconciliationJob.new.perform(@organization.id)
      assert_empty called
      event = EnterpriseSyncEvent.create!(workos_event_id: "event_manual_recent", event_type: "organization_membership.updated", occurred_at: Time.current,
        payload: { "organization_id" => @organization.workos_organization_id })
      Enterprise::EventProcessor.call(event)
      assert_equal [ @organization.id ], called
      assert event.reload.processed_at
    end
    assert_equal 1, EnterpriseReconciliationJob.concurrency_limit
    assert_equal @organization.id.to_s, EnterpriseReconciliationJob.new(@organization.id).concurrency_key.split("/").last
  end

  private

  def signed_in
    with_workos do
      with_workos_http do
        request.headers["Authorization"] = "Bearer #{workos_token({ "sub" => "user_admin", "sid" => "session_admin" })}"
        yield
      end
    end
  end
end
