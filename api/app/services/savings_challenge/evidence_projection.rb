module SavingsChallenge
  class EvidenceProjection
    def initialize(enrollment, sequence:, cutoff_on:, mode: :current, frozen_quality: nil)
      raise ArgumentError, "Unknown evidence evaluation mode" unless mode.in?([ :current, :historical ])
      @enrollment, @sequence, @cutoff, @mode, @frozen = enrollment, sequence, cutoff_on, mode, frozen_quality
    end

    def call
      versions = SavingsEvidenceVersion.where(savings_enrollment: @enrollment, approval_sequence: ..@sequence)
        .select("DISTINCT ON (savings_evidence_allocation_id) savings_evidence_versions.*")
        .order(:savings_evidence_allocation_id, approval_sequence: :desc).includes(:savings_evidence_allocation).to_a
      quality = versions.map do |version|
        eligible = version.proof_snapshot.select { |proof| proof.fetch("dependencies").all? { |row| Date.iso8601(row.fetch("posted_on")) <= @cutoff } }
        state = if version.state == "revoked"
          "revoked"
        elsif @mode == :current && (!SavingsChallenge::EvidenceProof.new(@enrollment).current?(version.proof_snapshot, cutoff_on: @enrollment.ends_on) ||
          version.savings_evidence_allocation.savings_entry_version.savings_entry.current_approved_version_id != version.savings_evidence_allocation.savings_entry_version_id)
          "stale"
        else
          "linked"
        end
        { "version_id" => version.id, "digest" => version.digest, "entry_version_id" => version.savings_evidence_allocation.savings_entry_version_id,
          "status" => state, "supported_cents" => state == "linked" ? eligible.sum { |proof| proof.fetch("amount_cents") } : 0 }
      end
      if @frozen
        raise ArgumentError, "Frozen evidence quality does not match approved history" unless @frozen.instance_of?(Array) && @frozen.size == quality.size
        quality = quality.zip(@frozen).map do |maximum, frozen|
          raise ArgumentError, "Invalid frozen evidence identity or subset" unless frozen.slice("version_id", "digest", "entry_version_id") == maximum.slice("version_id", "digest", "entry_version_id") &&
            ((frozen["status"] == maximum["status"] && frozen["supported_cents"] == maximum["supported_cents"]) ||
              (maximum["status"] == "linked" && frozen["status"] == "stale" && frozen["supported_cents"] == 0))
          frozen
        end
      end
      { quality: quality, support: quality.to_h { |row| [ row.fetch("entry_version_id"), row.fetch("supported_cents") ] } }
    end
  end
end
