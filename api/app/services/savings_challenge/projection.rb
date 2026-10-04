module SavingsChallenge
  class Projection
    CURRENT_PLAN = Object.new.freeze

    # A server-selected plan freezes milestone denominators. This argument is
    # never accepted from a public projection request without domain validation.
    def initialize(enrollment, cutoff_on: nil, approval_sequence: nil, plan_version_id: CURRENT_PLAN, evidence_mode: nil, frozen_evidence_quality: nil)
      @enrollment = enrollment
      @cutoff_on = cutoff_on || [ enrollment.local_today, enrollment.ends_on ].min
      @sequence = approval_sequence || enrollment.approval_sequence
      @plan_version_id = plan_version_id
      @evidence_mode = evidence_mode || (approval_sequence.nil? ? :current : :historical)
      @frozen_evidence_quality = frozen_evidence_quality
    end

    def call
      cutoff = Inputs.date!(@cutoff_on)
      sequence = Inputs.integer!(@sequence, minimum: 0, maximum: @enrollment.approval_sequence)
      # Approval-time selection precedes effective-date filtering: do not resurrect
      # an old version when a current correction moves its effective date later.
      heads = @enrollment.savings_entry_versions.where(approval_sequence: ..sequence)
        .select("DISTINCT ON (savings_entry_id) savings_entry_versions.*")
        .order(:savings_entry_id, approval_sequence: :desc).to_a
      counted = heads.select { |head| head.effective_on <= cutoff && !HouseholdFinance::SavingsProjection::EXCLUDED_FUNDING_SOURCES.include?(head.funding_source) }
      attestation = @enrollment.savings_zero_attestations.where(cutoff_on: cutoff, approval_sequence: ..sequence).order(approval_sequence: :desc).first
      plans = @enrollment.savings_plan_versions.where(approval_sequence: ..sequence)
      plan = if @plan_version_id.equal?(CURRENT_PLAN)
        plans.order(approval_sequence: :desc).first
      elsif @plan_version_id.nil?
        nil
      else
        plans.find(Inputs.id!(@plan_version_id))
      end
      evidence = EvidenceProjection.new(@enrollment, sequence: sequence, cutoff_on: cutoff, mode: @evidence_mode, frozen_quality: @frozen_evidence_quality).call
      result = HouseholdFinance::SavingsProjection.new(
        entries: heads.map { |head| head.projection_input.merge(evidence_supported_cents: evidence[:support].fetch(head.id, 0)) }, cutoff_on: cutoff, target_cents: plan&.target_cents,
        reporting_known: counted.any? || attestation.present?, zero_attested: counted.empty? && attestation.present?
      ).call
      result.merge(approval_sequence: sequence, accepted_plan_version_id: plan&.id, zero_attestation_id: attestation&.id, evidence_quality: evidence[:quality])
    end
  end
end
