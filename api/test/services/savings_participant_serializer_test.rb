require "test_helper"
require_relative "../support/savings_evidence_test_support"

class SavingsParticipantSerializerTest < ActiveSupport::TestCase
  include SavingsEvidenceTestSupport

  setup do
    travel_to Date.new(2026, 11, 1).in_time_zone("Pacific/Guam").noon
    setup_savings_context
  end
  teardown { travel_back }

  test "one ten and one hundred versions use one evidence projection and allocation map" do
    with_savings_runtime do
      savings_enroll
      # Publish realistic immutable entry versions under the same enrollment
      # sequence/head contract; no operation-runner setup is part of the count.
      @savings_enrollment.with_lock do
        100.times do |index|
          sequence = @savings_enrollment.approval_sequence + 1
          @savings_enrollment.update!(approval_sequence: sequence)
          entry = @savings_enrollment.savings_entries.create!
          version = entry.savings_entry_versions.create!(savings_enrollment: @savings_enrollment,
            approved_by_user: @savings_user, version_number: 1, approval_sequence: sequence,
            signed_cents: 100 + index, evidence_supported_cents: 0, effective_on: @savings_enrollment.local_today,
            currency: "USD", funding_source: "new_money_reserved", approved_at: Time.current, reason: "Synthetic approved reservation")
          entry.update!(current_approved_version: version)
        end
      end
      counts = [ 1, 10, 100 ].map do |size|
        rows = @savings_enrollment.savings_entry_versions.order(:id).limit(size).to_a
        queries = []
        subscriber = ->(_name, _start, _finish, _id, payload) { queries << payload[:sql] unless payload[:name] == "SCHEMA" || payload[:cached] }
        output = nil
        ApplicationRecord.uncached do
          ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
            output = SavingsChallenge::ParticipantSerializer.collection(rows, enrollment: @savings_enrollment)
          end
        end
        assert_equal rows.map(&:id), output.pluck("id")
        assert_equal [ "not_linked" ], output.pluck("evidence_status").uniq
        assert_equal [ 0 ], output.pluck("evidence_head_lock_version").uniq
        assert_equal 1, queries.grep(/DISTINCT ON.*savings_evidence_versions/).size
        assert_equal 1, queries.grep(/FROM "savings_evidence_allocations"/).size
        queries.size
      end
      assert_equal [ 2, 2, 2 ], counts
    end
  end

  test "batched current evidence matches single records and does not rewrite historical evidence" do
    with_evidence_operations do
      savings_enroll
      entry = savings_approve(savings_draft(10_001))
      source, = evidence_source(20_000)
      evidence_attach(entry, [ evidence_proof(source, amount: 5001) ])
      sequence = @savings_enrollment.reload.approval_sequence
      records = [ entry ]
      assert_equal records.map { |record| SavingsChallenge::ParticipantSerializer.record(record) },
        SavingsChallenge::ParticipantSerializer.collection(records, enrollment: @savings_enrollment)
      evidence_source_review(source.financial_source_event, identity: source.source_account_identity_version,
        amount: 19_999, type: "income", on: source.posted_on)
      serialized = SavingsChallenge::ParticipantSerializer.collection(records, enrollment: @savings_enrollment).sole
      assert_equal "stale", serialized["evidence_status"]
      assert_equal 0, serialized["evidence_supported_cents"]
      assert_equal 5001, savings_projection(approval_sequence: sequence)[:evidence_supported_cents]
      assert_raises(ArgumentError) do
        SavingsChallenge::ParticipantSerializer.collection(records, enrollment: SavingsEnrollment.new(id: -1))
      end
    end
  end
end
