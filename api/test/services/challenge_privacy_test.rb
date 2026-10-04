require "test_helper"
require_relative "../support/savings_challenge_test_support"

class ChallengePrivacyTest < ActiveSupport::TestCase
  include SavingsChallengeTestSupport
  setup do
    setup_savings_context
    travel_to Time.find_zone!("Pacific/Guam").local(2026, 11, 15, 12)
    with_savings_runtime { savings_enroll }
  end
  teardown { travel_back }

  class Adapter < ChallengePrivacy::SponsorExports::CheckpointAdapter
    attr_accessor :bands, :calls
    def initialize = (@bands, @calls = {}, 0)
    def validate_cutoff!(*_arguments, **_keywords) = true
    def snapshot(enrollment, checkpoint_day:, cutoff_on:)
      @calls += 1
      { enrollment_id: enrollment.id, checkpoint_id: enrollment.id, checkpoint_version: 1,
        cutoff_on: cutoff_on.iso8601, digest: "a" * 64, band: bands.fetch(enrollment.id, "at_target") }
    end
  end

  test "participation alone gives only basic help status and no private summary" do
    reader = shared
    assert_equal %i[check_in enrollment_id help_requests more_help_requests participation_status setup_status], reader.basic.keys.sort
    assert_raises(ChallengePrivacy::Access::Denied) { reader.summary }
    assert_equal 0, ChallengePrivacyGrant.count
    assert_equal 0, ChallengePrivacyRead.count
  end

  test "separate summary consent is revocable immediately without affecting participation" do
    with_savings_runtime do
      savings_plan
      savings_approve(savings_draft(100))
    end
    event = privacy_run(:consent, consent_input)
    assert_equal 100, shared.summary.dig(:projection, :reported_cents)
    grant = grant_for
    privacy_run(:consent, consent_input(granted: false, expected_grant_id: grant.id, expected_lock_version: grant.lock_version))
    assert_raises(ChallengePrivacy::Access::Denied) { shared.summary }
    assert_equal "active", @savings_enrollment.reload.status
    assert_equal 2, ChallengePrivacyEvent.count
    assert_equal 1, ChallengePrivacyRead.count
    operation(:consent).authorize_replay!(event)
  end

  test "selected source sharing permits one exact source only and never returns bearer storage URL" do
    source, other = source_file, source_file
    privacy_run(:consent, consent_input(kind: "selected_details", selected_records: [ ref(source) ], expires_at: 1.hour.from_now.iso8601))
    assert_equal source, shared.selected(**ref(source))
    assert_raises(ChallengePrivacy::Access::Denied) { shared.selected(**ref(other)) }
    assert_raises(ChallengePrivacy::Access::Denied) { shared.summary }
    travel 2.hours
    assert_raises(ChallengePrivacy::Access::Denied) { shared.selected(**ref(source)) }
  end

  test "staff role without current explicit program and workspace permissions cannot browse" do
    privacy_run(:consent, consent_input)
    @savings_owner.update!(role: "participant")
    assert_raises(ChallengePrivacy::Access::Denied) { shared.summary }
    @savings_owner.update!(role: "coach")
    CoachWorkspaceMembership.where(user: @savings_owner).delete_all
    assert_raises(ChallengePrivacy::Access::Denied) { shared.summary }
    admin = User.create!(clerk_id: SecureRandom.uuid, email: "admin-#{SecureRandom.hex(8)}@example.com", role: "admin")
    assert_raises(ChallengePrivacy::Access::Denied) { ChallengePrivacy::SharedReader.new(@savings_enrollment, user: admin).basic }
  end

  test "household partner and foreign record references do not inherit personal enrollment consent" do
    partner = User.create!(clerk_id: SecureRandom.uuid, email: "partner-#{SecureRandom.hex(8)}@example.com", role: "participant")
    @savings_household.household_memberships.create!(user: partner, role: "partner")
    assert_raises(ActiveRecord::RecordNotFound) { operation(:consent, user: partner).prepare(consent_input) }
    foreign_user = User.create!(clerk_id: SecureRandom.uuid, email: "foreign-#{SecureRandom.hex(8)}@example.com", role: "participant")
    other_household = HouseholdFinance::WorkspaceResolver.new(foreign_user).household
    foreign = source_file(household: other_household, uploader: foreign_user)
    assert_raises(ActiveRecord::RecordNotFound) { operation(:consent).prepare(consent_input(kind: "selected_details", selected_records: [ ref(foreign) ], expires_at: 1.hour.from_now.iso8601)) }
  end

  test "private chat sharing requires exact participant messages and no wildcard scope" do
    session = ChatSession.create!(household: @savings_household, user: @savings_user)
    message = session.chat_messages.create!(role: "user", content: "Synthetic private feeling")
    privacy_run(:consent, consent_input(kind: "selected_details", selected_records: [ { record_type: "chat_message", record_id: message.id } ], expires_at: 1.hour.from_now.iso8601))
    assert_equal message, shared.selected(record_type: "chat_message", record_id: message.id)
    assert_raises(ArgumentError) { operation(:consent).prepare(consent_input(kind: "selected_details", selected_records: [ { record_type: "all_chat", record_id: message.id } ], expires_at: 1.hour.from_now.iso8601)) }
    assert_raises(ArgumentError) { operation(:consent).prepare(consent_input.merge(include_all_household: true)) }
  end

  test "support ticket is participant chosen concise metadata with no automatic attachments" do
    event = privacy_run(:ticket, enrollment_id: @savings_enrollment.id, recipient_user_id: @savings_owner.id, issue_kind: "technical", message: "Synthetic issue reference QA-17", selected_records: [])
    ticket = ChallengeSupportTicket.find(event.subject_id)
    assert_empty ticket.selected_records
    result = shared.support_ticket(ticket.id)
    assert_equal "Synthetic issue reference QA-17", result[:message]
    assert_empty result[:selected_records]
    assert_equal "support_ticket", ChallengePrivacyRead.last.purpose
    assert_raises(ArgumentError) { operation(:ticket).prepare(enrollment_id: @savings_enrollment.id, recipient_user_id: @savings_owner.id, issue_kind: "technical", message: "x" * 501, selected_records: []) }
  end

  test "support grants require exact ticket recipient records reason and at most twenty four hours" do
    source = source_file
    event = privacy_run(:ticket, enrollment_id: @savings_enrollment.id, recipient_user_id: @savings_owner.id, issue_kind: "technical", message: "Synthetic rendering error", selected_records: [])
    ticket = ChallengeSupportTicket.find(event.subject_id)
    input = { enrollment_id: @savings_enrollment.id, ticket_id: ticket.id, recipient_user_id: @savings_owner.id,
      selected_records: [ ref(source) ], reason: "Review this one synthetic page", expires_at: 1.hour.from_now.iso8601, expected_ticket_lock_version: ticket.lock_version }
    assert_raises(ArgumentError) { operation(:support_grant).prepare(input.merge(expires_at: 25.hours.from_now.iso8601)) }
    result = privacy_run(:support_grant, input)
    access = ChallengeSupportAccess.find(result.subject_id)
    assert_equal source, shared.selected(**ref(source), support_access_id: access.id)
    privacy_run(:support_revoke, enrollment_id: @savings_enrollment.id, access_id: access.id, expected_lock_version: access.lock_version)
    assert_raises(ChallengePrivacy::Access::Denied) { shared.selected(**ref(source), support_access_id: access.id) }
  end

  test "stale privacy prepare cannot overwrite another tab and execution replay reauthorizes actual user" do
    prepared = operation(:consent).prepare(consent_input)
    privacy_run(:consent, consent_input)
    assert_raises(HouseholdFinance::Operations::Base::StaleOperation) { operation(:consent).execute!(prepared, source: "manual_ui") }
    event = ChallengePrivacyEvent.last
    @savings_household.household_memberships.find_by!(user: @savings_user).update!(role: "coach_viewer")
    assert_raises(ChallengePrivacy::Access::Denied) { operation(:consent).authorize_replay!(event) }
    assert_equal 1, ChallengePrivacyEvent.count
  end

  test "revoking sharing and global originals remains possible after withdrawal and release hold" do
    privacy_run(:consent, consent_input)
    source = source_file
    authorize_source(source)
    @savings_enrollment.update!(status: "withdrawn")
    @savings_cohort.update!(savings_challenge_release_hold: true)
    grant = grant_for
    privacy_run(:consent, consent_input(granted: false, expected_grant_id: grant.id, expected_lock_version: grant.lock_version))
    revoke_source(source)
    assert_not source.reload.source_available?
    assert_not FinancialSourceUse.last.active?
    assert_equal "pending", FinancialDocumentSourceCleanup.last.status
  end

  test "source uses disclose personal end plus thirty days and another join never extends silently" do
    source = source_file
    original_expiry = expiry(@savings_enrollment)
    authorize_source(source)
    assert_equal original_expiry, FinancialSourceUse.last.expires_at.iso8601
    later_cohort = Cohort.create!(name: "Later synthetic #{SecureRandom.hex(4)}", created_by_user: @savings_owner, status: "enrolling")
    later_cohort.cohort_memberships.create!(user: @savings_user, role: "participant")
    assert_equal original_expiry, retention.describe(source)[:latest_authorized_expiry]
    assert_raises(ArgumentError) { operation(:source_authorize).prepare(source_input(source).merge(expected_expires_at: 1.year.from_now.iso8601)).then { |prepared| operation(:source_authorize).execute!(prepared, source: "manual_ui") } }
    assert_equal 1, FinancialSourceUse.count
  end

  test "latest explicitly authorized source use survives early expiry and global owner revoke removes every use" do
    source = source_file
    authorize_source(source)
    later = another_enrollment(starts_on: @savings_enrollment.starts_on + 20)
    FinancialSourceUse.create!(household: later.household, participant_user: later.user, savings_enrollment: later, financial_document_import: source,
      authorized_at: Time.current, expires_at: expiry(later), disclosure_version: ChallengePrivacy::SourceRetention::DISCLOSURE_VERSION)
    travel_to FinancialSourceUse.order(:id).first.expires_at + 1.second
    assert ChallengePrivacy::SourceRetention.available?(source)
    assert_nil retention.expire!(source)
    revoke_source(source)
    assert_equal 0, FinancialSourceUse.where(revoked_at: nil).count
    assert_not source.reload.source_available?
  end

  test "expired explicit source access fails before cleanup and expiry creates durable obligation without touching storage" do
    source = source_file
    authorize_source(source)
    travel_to FinancialSourceUse.last.expires_at + 1.second
    assert_not ChallengePrivacy::SourceRetention.available?(source)
    cleanup = retention.expire!(source)
    assert_equal "pending", cleanup.status
    assert_not source.reload.source_available?
    assert_equal "qa/synthetic/#{source.id}", cleanup.s3_key
    assert_nil retention.expire!(source)&.completed_at
  end

  test "source revoke preview pins affected uses and unauthorized household role cannot extend or delete" do
    source = source_file
    authorize_source(source)
    input = source_revoke_input(source)
    prepared = operation(:source_revoke).prepare(input)
    FinancialSourceUse.last.update!(expires_at: 1.year.from_now)
    assert_raises(ArgumentError) { operation(:source_revoke).execute!(prepared, source: "manual_ui") }
    @savings_household.household_memberships.find_by!(user: @savings_user).update!(role: "coach_viewer")
    assert_raises(ChallengePrivacy::Access::Denied) { retention.describe(source) }
    assert source.reload.source_available?
  end

  test "global original deletion erases raw evidence but preserves approved financial source facts" do
    source = source_file
    attempt = source.attempts.create!(provider: "synthetic", model: "synthetic", prompt_version: "v1", schema_version: 2, status: "processing", started_at: Time.current)
    accounting = FinancialDocuments::AccountingContract.normalize({ contract_version: FinancialDocuments::AccountingContract::VERSION,
      accounts: [ { account_key: "checking", account_basis: "asset", period_start_on: "2026-11-01", period_end_on: "2026-11-30" } ],
      events: [ { account_key: "checking", row_kind: "posted", event_type: "purchase", signed_amount_cents: -1_000,
        posted_on: "2026-11-12", raw_description: "Synthetic private raw evidence", merchant: "Synthetic Pharmacy", locator: { page: 1, row: 1 } } ] })
    result = FinancialDocuments::SourceAccountingPersister.new(source, attempt: attempt, accounting: accounting).call
    runner = HouseholdFinance::Operations::Runner.new(@savings_household, user: @savings_user)
    invoke = ->(key, input) { runner.run(operation_key: key, input: input, idempotency_key: SecureRandom.uuid).subject }
    identity = invoke.call("source_review.account.link", { source_account_id: result[:events].first.financial_source_account_id, tracked_account_id: nil, account_id: nil, account_basis: "asset", label: "Synthetic checking", base_version_id: nil, base_lock_version: 0,
      statement_facts: { period_start_on: "2026-11-01", period_end_on: "2026-11-30" }, reason: "Reviewed synthetic account" })
    draft = invoke.call("source_review.draft.stage", { event_id: result[:events].first.id, base_version_id: nil, base_lock_version: 0, expected_pending_draft: nil,
      facts: { source_account_identity_version_id: identity.id, disposition: "include", event_type: "purchase", signed_amount_cents: -1_000,
        posted_on: "2026-11-12", authorized_on: nil, merchant: "Synthetic Pharmacy", budget_category_id: nil, purchase_amount_cents: 1_000, overlap_disposition: "new" },
      projection: { action: "none" }, reason: "Reviewed exact synthetic purchase" })
    approved = invoke.call("source_review.draft.approve", { draft_id: draft.id, draft_lock_version: draft.lock_version, draft_digest: draft.digest })
    assert FinancialSourceEvidence.where(financial_source_event: result[:events].first).exists?
    revoke_source(source)
    assert_equal(-1_000, approved.reload.signed_amount_cents)
    assert_equal approved.id, approved.source_review_head.reload.approved_version_id
    assert FinancialSourceEvent.exists?(result[:events].first.id)
    assert_empty FinancialSourceEvidence.where(financial_source_event: result[:events].first)
  end

  test "a twenty nine consented participant complement also suppresses the financial breakdown" do
    cohort = report_cohort(30)
    ChallengePrivacyGrant.where(savings_enrollment: SavingsEnrollment.where(cohort: cohort)).last.update!(granted: false)
    report = exporter(cohort, Adapter.new).approve(checkpoint_day: 30, resolved_cutoff_on: "2026-11-15")
    assert report["suppressed"]
    assert_equal "suppressed", report["active_consent_count_range"]
    assert_empty report["bands"]
  end

  test "fixed sponsor exports suppress cells zero through four and their complements" do
    adapter = Adapter.new
    (0..5).each do |count|
      # A separate fixed policy identity per cohort prevents rebuilding reports.
      cohort = report_cohort(count)
      report = exporter(cohort, adapter).approve(checkpoint_day: 30, resolved_cutoff_on: "2026-11-15")
      assert_equal count < 5, report["suppressed"]
      assert_equal count < 5 ? "suppressed" : "5-9", report["active_consent_count_range"]
      assert_equal count < 5 ? [] : [ { "band" => "at_target", "count_range" => "5-9" } ], report["bands"]
    end
  end

  test "twenty nine of thirty is suppressed and no exact money roster or slices are exported" do
    cohort = report_cohort(30)
    adapter = Adapter.new
    adapter.bands[SavingsEnrollment.where(cohort: cohort).last.id] = "below_target"
    service = exporter(cohort, adapter)
    report = service.approve(checkpoint_day: 30, resolved_cutoff_on: "2026-11-15")
    assert report["suppressed"]
    assert_empty report["bands"]
    assert_not report["exact_money_totals_included"]
    assert_not report["roster_included"]
    assert_raises(ArgumentError) { service.approve(checkpoint_day: 30, resolved_cutoff_on: "2026-11-15", department: "Small team") }
    assert_raises(ArgumentError) { service.approve(checkpoint_day: 31, resolved_cutoff_on: "2026-11-15") }
  end

  test "fixed replay never queries new checkpoint amounts and revoke invalidates rather than rebuilds" do
    cohort = report_cohort(5)
    adapter = Adapter.new
    service = exporter(cohort, adapter)
    first = service.approve(checkpoint_day: 30, resolved_cutoff_on: "2026-11-15")
    adapter.bands.transform_values! { "below_target" }
    assert_equal first, service.approve(checkpoint_day: 30, resolved_cutoff_on: "2026-11-15")
    assert_equal 5, adapter.calls
    grant = ChallengePrivacyGrant.where(savings_enrollment: SavingsEnrollment.where(cohort: cohort)).first
    grant.update!(granted: false)
    assert_raises(ChallengePrivacy::Access::Denied) { service.read(ChallengeSponsorExport.last.id) }
    assert_raises(ChallengePrivacy::Access::Denied) { service.approve(checkpoint_day: 30, resolved_cutoff_on: "2026-11-15") }
    assert_equal 1, ChallengeSponsorExport.count
  end

  test "checkpoint differencing suppresses one changed result and requires qualified snapshot adapter" do
    cohort = report_cohort(10)
    adapter = Adapter.new
    ids = SavingsEnrollment.where(cohort: cohort).order(:id).pluck(:id)
    ids.first(5).each { |id| adapter.bands[id] = "below_target" }
    service = exporter(cohort, adapter)
    refute service.approve(checkpoint_day: 30, resolved_cutoff_on: "2026-11-15")["suppressed"]
    adapter.bands[ids.first] = "at_target"
    assert service.approve(checkpoint_day: 60, resolved_cutoff_on: "2026-11-15")["suppressed"]
    assert_raises(ChallengePrivacy::Access::Denied) { ChallengePrivacy::SponsorExports.new(cohort, user: @savings_owner).approve(checkpoint_day: 90, resolved_cutoff_on: "2026-11-15") }
  end

  test "unknown final pending custom null target late and withdrawn are distinct qualified bands" do
    cohort = report_cohort(30)
    adapter = Adapter.new
    ids = SavingsEnrollment.where(cohort: cohort).order(:id).pluck(:id)
    %w[unknown final_pending custom_target no_target late_window withdrawn].each_with_index { |band, index| ids.slice(index * 5, 5).each { |id| adapter.bands[id] = band } }
    report = exporter(cohort, adapter).approve(checkpoint_day: 90, resolved_cutoff_on: "2026-11-15")
    refute report["suppressed"]
    assert_equal %w[custom_target final_pending late_window no_target unknown withdrawn], report["bands"].pluck("band").sort
    assert_not report.key?("total_savings_cents")
  end

  test "private audit history and fixed exports are SQL immutable and cross participant scope is guarded" do
    event = privacy_run(:consent, consent_input)
    assert_raises(ActiveRecord::StatementInvalid) { ChallengePrivacyEvent.transaction(requires_new: true) { ChallengePrivacyEvent.where(id: event.id).update_all(approved_values: {}) } }
    assert_raises(ActiveRecord::StatementInvalid) { ChallengePrivacyGrant.transaction(requires_new: true) { grant_for.update_columns(participant_user_id: @savings_owner.id) } }
    report = exporter(report_cohort(5), Adapter.new).approve(checkpoint_day: 30, resolved_cutoff_on: "2026-11-15")
    assert_raises(ActiveRecord::StatementInvalid) { ChallengeSponsorExport.transaction(requires_new: true) { ChallengeSponsorExport.last.update_columns(report: report.merge("bands" => [])) } }
    assert [ HouseholdFinance::Operations::Privacy::ConsentSet, HouseholdFinance::Operations::Privacy::SupportAccessGrant ].all? { |klass| klass::ACTOR_REQUIRED && klass::SENSITIVE_AUDIT }
  end

  test "CSV formula escaping includes whitespace and preserves displayed input" do
    [ "=SUM(A1)", "+5", "@command", "-42", "\t =formula" ].each { |value| assert_equal "'#{value}", ChallengePrivacy::SponsorExports.escape_cell(value) }
    assert_equal "ordinary text", ChallengePrivacy::SponsorExports.escape_cell("ordinary text")
    assert_equal "5-9", ChallengePrivacy::SponsorExports.escape_cell("5-9")
  end

  private
  def operation(action, user: @savings_user)
    klass = { consent: "ConsentSet", ticket: "SupportRequestCreate", support_grant: "SupportAccessGrant", support_revoke: "SupportAccessRevoke", source_authorize: "SourceUseAuthorize", source_revoke: "SourceUseRevoke" }.fetch(action)
    HouseholdFinance::Operations::Privacy.const_get(klass).new(@savings_household, user: user)
  end
  def privacy_run(action, input)
    op = operation(action)
    prepared = op.prepare(input)
    result = op.execute!(prepared, source: "manual_ui")
    assert op.verify_after!(prepared.predicted_after_snapshot, op.after_snapshot(result, prepared))
    result
  end
  def consent_input(**options)
    { enrollment_id: @savings_enrollment.id, kind: "coach_summary", recipient_user_id: @savings_owner.id, granted: true,
      selected_records: [], expires_at: nil, policy_version: "challenge_privacy_v1", expected_grant_id: nil, expected_lock_version: 0 }.merge(options)
  end
  def grant_for = ChallengePrivacyGrant.find_by!(savings_enrollment: @savings_enrollment, kind: "coach_summary")
  def shared = ChallengePrivacy::SharedReader.new(@savings_enrollment, user: @savings_owner)
  def ref(source) = { record_type: "document_source", record_id: source.id }
  def source_file(household: @savings_household, uploader: @savings_user)
    source = FinancialDocumentImport.create!(household: household, uploaded_by_user: uploader, document_kind: "statement", status: "needs_review", filename: "synthetic.pdf", content_type: "application/pdf", byte_size: 10, s3_key: "qa/synthetic/#{SecureRandom.hex(8)}")
    source.update!(s3_key: "qa/synthetic/#{source.id}")
    source
  end
  def retention = ChallengePrivacy::SourceRetention.new(@savings_household, user: @savings_user)
  def expiry(enrollment) = (enrollment.ends_on.in_time_zone(enrollment.time_zone).end_of_day + 30.days).iso8601
  def source_input(source)
    { enrollment_id: @savings_enrollment.id, document_import_id: source.id, disclosure_version: ChallengePrivacy::SourceRetention::DISCLOSURE_VERSION,
      expected_expires_at: expiry(@savings_enrollment), expected_use_id: nil, expected_lock_version: 0 }
  end
  def authorize_source(source) = privacy_run(:source_authorize, source_input(source))
  def source_revoke_input(source) = { enrollment_id: @savings_enrollment.id, document_import_id: source.id, expected_affected_uses_digest: HouseholdFinance::Operations::PreparedOperation.fingerprint(retention.describe(source)[:affected_uses]) }
  def revoke_source(source) = privacy_run(:source_revoke, source_revoke_input(source))
  def another_enrollment(starts_on: @savings_enrollment.starts_on)
    user = User.create!(clerk_id: SecureRandom.uuid, email: "s08-#{SecureRandom.hex(8)}@example.com", role: "participant")
    @savings_household.household_memberships.create!(user: user, role: "partner")
    membership = @savings_cohort.cohort_memberships.create!(user: user, role: "participant")
    SavingsEnrollment.create!(household: @savings_household, user: user, cohort: @savings_cohort, accepted_cohort_release: @savings_release,
      accepted_cohort_membership_id: membership.id, membership_started_at: membership.created_at, accepted_at: Time.current,
      accepted_local_on: @savings_enrollment.accepted_local_on, starts_on: starts_on, ends_on: starts_on + 89, policy_version: "1")
  end
  def report_cohort(count)
    cohort = Cohort.create!(name: "Report #{SecureRandom.hex(8)}", status: "enrolling", created_by_user: @savings_owner, starts_on: Date.new(2026, 11, 1), savings_challenge_enabled: true, savings_challenge_release_hold: false)
    config = cohort.cohort_experience_configuration
    config.update!(draft_config: CohortExperience::Schema::PILOT_SAVINGS_CONFIG)
    pub = CohortExperience::Publisher.new(configuration: config, actor: @savings_owner)
    preview = pub.preview!(expected_draft_revision: config.draft_revision)
    pub.publish!(expected_preview_digest: preview, expected_draft_revision: config.draft_revision, expected_current_version_id: nil)
    release = CohortReleases::Sealer.new(cohort: cohort, actor: nil, publication_source: "system").call!(request_key: "s08-report-fixture")
    CohortReleases::RuntimeActivator.new(cohort: cohort).call!
    count.times do
      user = User.create!(clerk_id: SecureRandom.uuid, email: "report-#{SecureRandom.hex(8)}@example.com", role: "participant")
      household = HouseholdFinance::WorkspaceResolver.new(user).household
      member = cohort.cohort_memberships.create!(user: user, role: "participant")
      enrollment = SavingsEnrollment.create!(household: household, user: user, cohort: cohort, accepted_cohort_release: release,
        accepted_cohort_membership_id: member.id, membership_started_at: member.created_at, accepted_at: Time.current, accepted_local_on: Date.new(2026, 11, 15),
        starts_on: Date.new(2026, 11, 15), ends_on: Date.new(2026, 11, 15) + 89, policy_version: "1")
      ChallengePrivacyGrant.create!(household: household, participant_user: user, savings_enrollment: enrollment, kind: "sponsor_aggregate", granted: true, policy_version: "challenge_privacy_v1")
    end
    cohort
  end
  def exporter(cohort, adapter) = ChallengePrivacy::SponsorExports.new(cohort, user: @savings_owner, adapter: adapter)
end
