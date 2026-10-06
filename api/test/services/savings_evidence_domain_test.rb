require "test_helper"
require_relative "../support/savings_evidence_test_support"

class SavingsEvidenceDomainTest < ActiveSupport::TestCase
  include SavingsEvidenceTestSupport

  setup do
    travel_to Date.new(2026, 11, 1).in_time_zone("Pacific/Guam").noon
    setup_savings_context
  end

  teardown { travel_back }

  test "partial proof changes only supported subset and consumes supported cents first" do
    with_evidence_operations do
      savings_enroll
      savings_plan
      entry = savings_approve(savings_draft(20_000))
      savings_approve(savings_draft(10_000))
      source, = evidence_source
      before = savings_projection
      evidence_attach(entry, [ evidence_proof(source, amount: 20_000) ])
      assert_equal before[:reported_cents], savings_projection[:reported_cents]
      assert_equal 20_000, savings_projection[:evidence_supported_cents]
      assert_equal 0, entry.reload.evidence_supported_cents
      savings_approve(savings_draft(-15_000, funding: "withdrawal"))
      assert_equal 15_000, savings_projection[:reported_cents]
      assert_equal 5_000, savings_projection[:evidence_supported_cents]
      assert_equal "linked", SavingsChallenge::ParticipantSerializer.record(entry)["evidence_status"]
      assert_empty @savings_household.household_transactions
    end
  end

  test "same-day evidence FIFO uses numeric entry chronology across a decimal identity boundary" do
    with_evidence_operations do
      savings_enroll
      identities = [ 999_999_999, 1_000_000_000, 1_000_000_001 ].map do |id|
        SavingsEntry.create!(id: id, savings_enrollment: @savings_enrollment)
      end
      first = savings_approve(savings_draft(20_000, entry: identities[0]))
      second = savings_approve(savings_draft(10_000, entry: identities[1]))
      source, = evidence_source
      evidence_attach(first, [ evidence_proof(source, amount: 20_000) ])
      before_withdrawal = @savings_enrollment.reload.approval_sequence
      withdrawal = savings_approve(savings_draft(-15_000, entry: identities[2], funding: "withdrawal"))
      current = savings_projection
      assert_equal 15_000, current[:reported_cents]
      assert_equal 5_000, current[:evidence_supported_cents]
      assert_equal [ first, second, withdrawal ].map { |version| "version-#{version.id}" }, current[:included_version_ids]
      earlier = savings_projection(approval_sequence: before_withdrawal)
      assert_equal 30_000, earlier[:reported_cents]
      assert_equal 20_000, earlier[:evidence_supported_cents]
    end
  end

  test "one partial lot supports fifty then withdrawal twenty five leaves supported twenty five" do
    with_evidence_operations do
      savings_enroll
      entry = savings_approve(savings_draft(10_000))
      source, = evidence_source
      evidence_attach(entry, [ evidence_proof(source, amount: 5_000) ])
      savings_approve(savings_draft(-2_500, funding: "withdrawal"))
      assert_equal 7_500, savings_projection[:reported_cents]
      assert_equal 2_500, savings_projection[:evidence_supported_cents]
    end
  end

  test "two bank legs and aliases share one canonical capacity" do
    with_evidence_operations do
      savings_enroll
      first = savings_approve(savings_draft(10_000))
      second = savings_approve(savings_draft(10_000))
      debit, = evidence_source(-10_000, type: "transfer")
      credit, = evidence_source(10_000, type: "transfer")
      group = evidence_group(debit, credit)
      evidence_attach(first, [ evidence_proof(debit, amount: 6_000, group: group) ])
      assert_raises(ArgumentError) do
        evidence_attach(second, [ evidence_proof(credit, amount: 5_000, group: group) ])
      end
      evidence_attach(second, [ evidence_proof(credit, amount: 4_000, group: group) ])
      assert_equal 10_000, savings_projection[:evidence_supported_cents]
      assert_equal 4, SavingsEvidenceCapacity.count
      assert_equal 20_000, savings_projection[:reported_cents]
    end
  end

  test "source correction invalidates current support but retains historical sequence and capacity" do
    with_evidence_operations do
      savings_enroll
      first = savings_approve(savings_draft(10_000))
      source, = evidence_source(10_000)
      evidence = evidence_attach(first, [ evidence_proof(source, amount: 8_000) ]).subject
      sequence = @savings_enrollment.reload.approval_sequence
      corrected = evidence_source_review(source.financial_source_event, identity: source.source_account_identity_version, amount: 9_000, type: "income", on: source.posted_on)
      assert_equal 0, savings_projection[:evidence_supported_cents]
      assert_equal "stale", savings_projection[:evidence_quality].sole["status"]
      assert_equal 8_000, savings_projection(approval_sequence: sequence)[:evidence_supported_cents]
      second = savings_approve(savings_draft(5_000))
      assert_raises(ArgumentError) { evidence_attach(second, [ evidence_proof(corrected, amount: 2_000) ]) }
      evidence_revoke(evidence)
      evidence_attach(second, [ evidence_proof(corrected, amount: 2_000) ])
      assert_equal 2_000, savings_projection[:evidence_supported_cents]
    end
  end

  test "monetary correction never inherits old proof and revoked historical versions remain immutable" do
    with_evidence_operations do
      savings_enroll
      entry = savings_approve(savings_draft(10_000))
      source, = evidence_source
      proof = evidence_attach(entry, [ evidence_proof(source, amount: 5_000) ]).subject
      sequence = @savings_enrollment.reload.approval_sequence
      savings_approve(savings_draft(9_000, entry: entry.savings_entry))
      assert_equal 9_000, savings_projection[:reported_cents]
      assert_equal 0, savings_projection[:evidence_supported_cents]
      assert_equal 5_000, savings_projection(approval_sequence: sequence)[:evidence_supported_cents]
      evidence_revoke(proof)
      assert_equal "revoked", proof.savings_evidence_allocation.reload.current_version.state
      assert_raises(ActiveRecord::RecordNotSaved) { proof.update!(supported_cents: 4_000) }
      assert_raises(ActiveRecord::StatementInvalid) { ApplicationRecord.transaction(requires_new: true) { SavingsEvidenceVersion.where(id: proof.id).update_all(supported_cents: 4_000) } }
    end
  end

  test "raw source deletion preserves reviewed truth and evidence support" do
    with_evidence_operations do
      savings_enroll
      entry = savings_approve(savings_draft(10_000))
      source, import = evidence_source
      evidence_attach(entry, [ evidence_proof(source, amount: 10_000) ])
      # Domain facts retain their canonical identities after the revocation path
      # removes raw source evidence; no S3 service is called by this test.
      source.financial_source_event.financial_source_evidence.destroy!
      import.update!(source_deleted_at: Time.current, status: "source_deleted")
      assert_equal 10_000, savings_projection[:evidence_supported_cents]
      assert_equal 0, entry.reload.evidence_supported_cents
    end
  end

  test "unknown refunds borrowed existing and ungrouped transfers cannot manufacture proof" do
    with_evidence_operations do
      savings_enroll
      entry = savings_approve(savings_draft(10_000))
      %w[refund transfer adjustment].each do |type|
        source, = evidence_source(10_000, type: type)
        assert_raises(ArgumentError) { evidence_attach(entry, [ evidence_proof(source, amount: 10_000) ]) }
      end
      source, = evidence_source
      %w[preexisting borrowed cash_advance existing_internal_money].each do |funding|
        excluded = savings_approve(savings_draft(10_000, funding: funding))
        assert_raises(ArgumentError) { evidence_attach(excluded, [ evidence_proof(source, amount: 10_000) ]) }
      end
      assert_equal 0, savings_projection[:evidence_supported_cents]
    end
  end

  test "strict review digests cents acceptance duplicate proofs and contribution ceiling fail closed" do
    with_evidence_operations do
      savings_enroll
      entry = savings_approve(savings_draft(10_000))
      source, = evidence_source
      proof = evidence_proof(source, amount: 5_000)
      [ proof.merge(amount_cents: 0), proof.merge(amount_cents: 0.5), proof.merge(amount_cents: "5000"), proof.merge(expected_source_digest: "a" * 64),
        proof.merge(expected_account_identity_digest: "a" * 64), proof.merge(amount_cents: 10_001), proof.merge(actor_id: @savings_user.id) ].each do |bad|
        assert_raises(ArgumentError) { evidence_attach(entry, [ bad ]) }
      end
      assert_raises(ArgumentError) { evidence_attach(entry, [ proof, proof ]) }
      assert_raises(ArgumentError) { savings_run("evidence.attach", evidence_input(entry, [ proof ]).merge(participant_ownership_accepted: false)) }
      assert_raises(ArgumentError) { savings_run("evidence.attach", evidence_input(entry, [ proof ]).merge(new_money_reservation_accepted: false)) }
      assert_empty SavingsEvidenceVersion.all
    end
  end

  test "retries replay safely and generic execution audit contains no evidence facts" do
    with_evidence_operations do
      savings_enroll
      entry = savings_approve(savings_draft(10_000))
      source, = evidence_source
      input = evidence_input(entry, [ evidence_proof(source, amount: 5_000) ])
      result = savings_run("evidence.attach", input, token: "private evidence retry")
      replay = savings_run("evidence.attach", input, token: "private evidence retry")
      assert replay.replayed?
      assert_equal result.subject.id, replay.subject.id
      assert_equal 1, SavingsEvidenceVersion.count
      %w[normalized_input before_snapshot predicted_after_snapshot after_snapshot].each { |key| assert_empty result.execution.public_send(key) }
      assert_empty result.execution.household_audit_event.metadata["normalized_input"]
      @savings_user.update!(role: "coach")
      assert_raises(SavingsChallenge::AccessPolicy::Unavailable) { savings_run("evidence.attach", input, token: "private evidence retry") }
    end
  end

  test "cutoff excludes later posted proof independently of approval sequence" do
    with_evidence_operations do
      savings_enroll
      entry = savings_approve(savings_draft(10_000))
      travel_to Date.new(2026, 11, 2).in_time_zone("Pacific/Guam").noon
      source, = evidence_source
      evidence_attach(entry, [ evidence_proof(source, amount: 5_000) ])
      assert_equal 0, savings_projection(cutoff_on: Date.new(2026, 11, 1))[:evidence_supported_cents]
      assert_equal 5_000, savings_projection[:evidence_supported_cents]
      assert_equal 0, savings_projection(approval_sequence: entry.approval_sequence)[:evidence_supported_cents]
    end
  end

  test "matched aliases cannot reserve canonical capacity a second time" do
    with_evidence_operations do
      savings_enroll
      entry = savings_approve(savings_draft(10_000))
      other = savings_approve(savings_draft(10_000))
      canonical, = evidence_source(10_000)
      copy, = evidence_source(10_000, tracked: canonical.source_tracked_account)
      matched = evidence_source_review(copy.financial_source_event, identity: copy.source_account_identity_version, amount: 10_000, type: "income", on: copy.posted_on, disposition: "match", matched: canonical)
      evidence_attach(entry, [ evidence_proof(matched, amount: 6_000) ])
      assert_raises(ArgumentError) { evidence_attach(other, [ evidence_proof(canonical, amount: 5_000) ]) }
      assert_equal canonical.financial_source_event.id, SavingsEvidenceCapacity.sole.financial_source_event_id
      evidence_attach(other, [ evidence_proof(canonical, amount: 4_000) ])
      assert_equal 10_000, savings_projection[:evidence_supported_cents]
    end
  end

  test "account remap invalidates support and prepared requests reject changed proof" do
    with_evidence_operations do
      savings_enroll
      entry = savings_approve(savings_draft(10_000))
      source, = evidence_source
      proof = evidence_proof(source, amount: 5_000)
      operation = HouseholdFinance::Operations::Savings::Evidence::Attach.new(@savings_household, user: @savings_user)
      prepared = operation.prepare(evidence_input(entry, [ proof ]).merge(cohort_id: @savings_cohort.id))
      evidence_attach(entry, [ proof ])
      identity = source.source_account_identity_version
      account = identity.source_account_review_head.financial_source_account
      source_operation(HouseholdFinance::Operations::SourceReview::AccountLink, source_account_id: account.id, account_basis: "asset", label: "Corrected synthetic identity",
        base_version_id: identity.id, base_lock_version: identity.source_account_review_head.reload.lock_version, statement_facts: identity.statement_facts, reason: "Reviewed corrected identity")
      assert_equal 0, savings_projection[:evidence_supported_cents]
      assert_raises(ArgumentError) { ApplicationRecord.transaction { operation.execute!(prepared, source: "manual") } }
    end
  end

  test "household partners may allocate their portion but cannot change another participant entry" do
    with_evidence_operations do
      savings_enroll
      original = @savings_enrollment
      entry = savings_approve(savings_draft(10_000))
      source, = evidence_source(10_000)
      evidence_attach(entry, [ evidence_proof(source, amount: 5_000) ])
      owner = @savings_user
      @savings_user = User.create!(clerk_id: "evidence-partner-#{SecureRandom.hex(8)}", email: "partner-#{SecureRandom.hex(8)}@example.com", role: "participant", invitation_status: "accepted")
      @savings_household.household_memberships.create!(user: @savings_user, role: "partner")
      @savings_cohort.cohort_memberships.create!(user: @savings_user, role: "participant")
      savings_enroll
      partner_entry = savings_approve(savings_draft(10_000))
      assert_raises(ActiveRecord::RecordNotFound) { evidence_attach(entry, [ evidence_proof(source, amount: 5_000) ]) }
      assert_raises(ArgumentError) { evidence_attach(partner_entry, [ evidence_proof(source, amount: 6_000) ]) }
      evidence_attach(partner_entry, [ evidence_proof(source, amount: 5_000) ])
      assert_equal 5_000, savings_projection[:evidence_supported_cents]
      assert_equal 5_000, SavingsChallenge::Projection.new(original.reload).call[:evidence_supported_cents]
      assert_equal owner.id, original.user_id
    end
  end

  test "one participant in another program does not receive a fresh household capacity" do
    with_evidence_operations do
      savings_enroll
      entry = savings_approve(savings_draft(10_000))
      source, = evidence_source(10_000)
      evidence_attach(entry, [ evidence_proof(source, amount: 6_000) ])
      @savings_cohort = Cohort.create!(name: "Second synthetic program", status: "enrolling", created_by_user: @savings_owner,
        starts_on: Date.new(2026, 11, 1), savings_challenge_enabled: true, savings_challenge_release_hold: false)
      @savings_cohort.cohort_memberships.create!(user: @savings_user, role: "participant")
      @savings_release = nil
      with_savings_runtime do
        savings_enroll
        other = savings_approve(savings_draft(10_000))
        assert_raises(ArgumentError) { evidence_attach(other, [ evidence_proof(source, amount: 5_000) ]) }
        evidence_attach(other, [ evidence_proof(source, amount: 4_000) ])
        assert_equal 4_000, savings_projection[:evidence_supported_cents]
      end
    end
  end

  test "held or removed memberships and foreign household sources fail before approval" do
    with_evidence_operations do
      savings_enroll
      entry = savings_approve(savings_draft(10_000))
      source, = evidence_source
      input = evidence_input(entry, [ evidence_proof(source, amount: 5_000) ])
      own_household = @savings_household
      @savings_household = Household.create!(created_by_user: @savings_user, name: "Other synthetic evidence household")
      @savings_household.household_memberships.create!(user: @savings_user, role: "partner")
      foreign, = evidence_source
      @savings_household = own_household
      assert_raises(ActiveRecord::RecordNotFound) { evidence_attach(entry, [ evidence_proof(foreign, amount: 5_000) ]) }
      @savings_cohort.update!(savings_challenge_release_hold: true)
      assert_raises(SavingsChallenge::AccessPolicy::Unavailable) { savings_run("evidence.attach", input) }
      @savings_cohort.update!(savings_challenge_release_hold: false)
      @savings_membership.destroy!
      assert_raises(SavingsChallenge::AccessPolicy::Unavailable) { savings_run("evidence.attach", input) }
      assert_empty SavingsEvidenceVersion.all
    end
  end

  test "closed checkpoint freezes quality and correction captures stale proof explicitly" do
    with_evidence_operations do
      savings_enroll
      savings_plan
      entry = savings_approve(savings_draft(10_000))
      source, = evidence_source
      evidence_attach(entry, [ evidence_proof(source, amount: 5_000) ])
      travel_to Date.new(2026, 11, 30).in_time_zone("Pacific/Guam").noon
      closed = checkpoint_approve(checkpoint_stage(30))
      original = closed.snapshot.deep_dup
      evidence_source_review(source.financial_source_event, identity: source.source_account_identity_version, amount: 19_000, type: "income", on: source.posted_on)
      assert_equal original, closed.reload.snapshot
      assert_equal 5_000, original.dig("savings", "evidence_supported_cents")
      assert SavingsChallenge::CheckpointSnapshot.validate!(enrollment: @savings_enrollment.reload, checkpoint: closed.savings_checkpoint, snapshot: original, historical: true)
      revised = checkpoint_approve(checkpoint_stage(30))
      assert_equal closed.id, revised.previous_version_id
      assert_equal 0, revised.snapshot.dig("savings", "evidence_supported_cents")
      assert_equal "stale", revised.snapshot.dig("savings", "evidence_quality").sole["status"]
    end
  end

  test "several independent proof amounts combine once and replacement frees only replaced capacities" do
    with_evidence_operations do
      savings_enroll
      entry = savings_approve(savings_draft(10_000))
      first, = evidence_source(5_000)
      second, = evidence_source(5_000)
      approved = evidence_attach(entry, [ evidence_proof(first, amount: 3_000), evidence_proof(second, amount: 2_000) ]).subject
      assert_equal 5_000, savings_projection[:evidence_supported_cents]
      replacement = evidence_attach(entry, [ evidence_proof(second, amount: 4_000) ]).subject
      assert_equal approved.id, replacement.previous_version_id
      assert_equal 4_000, savings_projection[:evidence_supported_cents]
      other = savings_approve(savings_draft(5_000))
      evidence_attach(other, [ evidence_proof(first, amount: 5_000) ])
      assert_equal 9_000, savings_projection[:evidence_supported_cents]
      assert_raises(ActiveRecord::StatementInvalid) do
        ApplicationRecord.transaction(requires_new: true) do
          approved.savings_evidence_capacities.create!(financial_source_event: second.financial_source_event, source_review_version: second, reserved_cents: 1, capacity_cents: 5_000)
        end
      end
    end
  end

  test "source outside challenge and liability account identity cannot establish reserve proof" do
    with_evidence_operations do
      savings_enroll
      entry = savings_approve(savings_draft(10_000))
      old, = evidence_source(10_000, on: Date.new(2026, 10, 31))
      assert_raises(ArgumentError) { evidence_attach(entry, [ evidence_proof(old, amount: 5_000) ]) }
      source, = evidence_source
      identity = source.source_account_identity_version
      account = identity.source_account_review_head.financial_source_account
      new_identity = source_operation(HouseholdFinance::Operations::SourceReview::AccountLink, source_account_id: account.id, account_basis: "liability", label: "Reviewed credit account",
        base_version_id: identity.id, base_lock_version: identity.source_account_review_head.reload.lock_version, statement_facts: identity.statement_facts, reason: "Reviewed liability basis")
      corrected = evidence_source_review(source.financial_source_event, identity: new_identity, amount: 20_000, type: "income", on: source.posted_on)
      assert_raises(ArgumentError) { evidence_attach(entry, [ evidence_proof(corrected, amount: 5_000) ]) }
    end
  end

  test "SQL forbids late capacity inserts support mutation head substitution and financial sequence reuse" do
    with_evidence_operations do
      savings_enroll
      entry = savings_approve(savings_draft(10_000))
      source, = evidence_source
      approved = evidence_attach(entry, [ evidence_proof(source, amount: 5_000) ]).subject
      capacity = approved.savings_evidence_capacities.sole
      assert_raises(ActiveRecord::StatementInvalid) { ApplicationRecord.transaction(requires_new: true) { capacity.update_columns(reserved_cents: 4_000) } }
      assert_raises(ActiveRecord::StatementInvalid) { ApplicationRecord.transaction(requires_new: true) { approved.savings_evidence_capacities.create!(financial_source_event: source.financial_source_event, source_review_version: source, reserved_cents: 1, capacity_cents: 20_000) } }
      assert_raises(ActiveRecord::StatementInvalid) { ApplicationRecord.transaction(requires_new: true) { SavingsEvidenceAllocation.where(id: approved.savings_evidence_allocation_id).update_all(current_version_id: nil) } }
      assert_raises(ActiveRecord::StatementInvalid) { ApplicationRecord.transaction(requires_new: true) { entry.update_columns(evidence_supported_cents: 5_000) } }
      assert_raises(ActiveRecord::StatementInvalid) do
        ApplicationRecord.transaction(requires_new: true) do
          @savings_enrollment.reload.update!(approval_sequence: approved.approval_sequence)
          @savings_enrollment.savings_plan_versions.create!(approved_by_user: @savings_user, version_number: 1, approval_sequence: approved.approval_sequence,
            target_cents: 50_000, approved_at: Time.current, reason: "Synthetic reused sequence")
        end
      end
    end
  end

  test "source correction after checkpoint staging requires a freshly reviewed snapshot" do
    with_evidence_operations do
      savings_enroll
      entry = savings_approve(savings_draft(10_000))
      source, = evidence_source
      evidence_attach(entry, [ evidence_proof(source, amount: 5_000) ])
      travel_to Date.new(2026, 11, 30).in_time_zone("Pacific/Guam").noon
      draft = checkpoint_stage(30)
      evidence_source_review(source.financial_source_event, identity: source.source_account_identity_version, amount: 19_000, type: "income", on: source.posted_on)
      assert_raises(ArgumentError) { checkpoint_approve(draft) }
      assert_equal "pending", draft.reload.status
      assert_empty SavingsCheckpointVersion.all
    end
  end
end
