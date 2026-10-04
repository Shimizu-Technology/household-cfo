module SavingsChallenge
  # Only reviewed canonical facts establish identity. Date/amount similarity and
  # raw extraction facts are never a substitute for an approved source head.
  class EvidenceProof
    def initialize(enrollment)
      @enrollment = enrollment
      @household = enrollment.household
    end

    def resolve(input)
      origin = SourceReviewVersion.where(household: @household).find(input.fetch(:source_review_version_id))
      check_digest!(origin.digest, input.fetch(:expected_source_digest))
      check_digest!(origin.source_account_identity_version.digest, input.fetch(:expected_account_identity_digest))
      validate_current!(origin)
      canonical = origin.disposition == "match" ? origin.matched_version : origin
      raise ArgumentError, "Choose an approved canonical movement" unless canonical&.disposition == "include"
      validate_current!(canonical)
      group_id = input.fetch(:economic_group_version_id)
      group = group_id && SourceEconomicGroupVersion.where(household: @household).find(group_id)
      if group
        check_digest!(group.digest, input.fetch(:expected_group_digest))
        raise ArgumentError, "Review the current transfer group" unless group.source_economic_group.approved_version_id == group.id && group.kind == "transfer"
        members = group.source_economic_memberships.includes(source_review_version: :source_account_identity_version).to_a
        versions = members.map(&:source_review_version)
        raise ArgumentError, "Only a reviewed two-account asset transfer establishes a reservation movement" unless members.size == 2 && versions.include?(canonical) &&
          members.all? { |row| row.role == "movement" } && versions.map { |version| version.source_tracked_account.id }.uniq.size == 2
        versions.each { |version| validate_current!(version) }
        raise ArgumentError, "Card payments and other movements are not reserve evidence" unless versions.all? { |version| version.disposition == "include" && version.event_type == "transfer" } &&
          versions.one? { |version| version.signed_amount_cents.positive? } && versions.one? { |version| version.signed_amount_cents.negative? } && members.map(&:allocation_cents).uniq.size == 1
        ceiling = members.first.allocation_cents
      else
        raise ArgumentError, "A transfer requires its reviewed economic group" unless canonical.event_type == "income" && canonical.signed_amount_cents.positive?
        raise ArgumentError, "This movement belongs to an economic group; review that group" if active_groups_for(canonical).any?
        versions = [ canonical ]
        ceiling = canonical.signed_amount_cents
      end
      amount = input.fetch(:amount_cents)
      raise ArgumentError, "Evidence allocation exceeds the reviewed movement" if amount > ceiling
      dependencies = ([ origin ] + versions).uniq(&:id)
      {
        "amount_cents" => amount, "capacity_cents" => ceiling,
        "group_version_id" => group&.id, "group_digest" => group&.digest,
        "dependencies" => dependencies.map { |version| dependency(version) },
        "bindings" => versions.map { |version| { "event_id" => version.financial_source_event.id, "source_review_version_id" => version.id,
          "capacity_cents" => ceiling, "reserved_cents" => amount } }.sort_by { |row| row.fetch("event_id") }
      }
    end

    def current?(snapshot, cutoff_on:)
      snapshot.all? do |proof|
        dependencies = proof.fetch("dependencies").map do |row|
          version = SourceReviewVersion.where(household: @household).find(row.fetch("version_id"))
          validate_current!(version)
          check_digest!(version.digest, row.fetch("digest"))
          check_digest!(version.source_account_identity_version.digest, row.fetch("identity_digest"))
          raise ArgumentError, "Evidence postdates the cutoff" if version.posted_on > cutoff_on
          version
        end
        group_id = proof.fetch("group_version_id")
        if group_id
          group = SourceEconomicGroupVersion.where(household: @household).find(group_id)
          raise ArgumentError, "Evidence group changed" unless group.source_economic_group.approved_version_id == group.id && group.digest == proof.fetch("group_digest")
          members = group.source_economic_memberships
          raise ArgumentError, "Evidence membership changed" unless members.map(&:source_review_version_id).sort == proof.fetch("bindings").map { |row| row.fetch("source_review_version_id") }.sort
          raise ArgumentError, "Evidence movement regrouped" if dependencies.any? { |version| active_groups_for(version).any? { |other| other.id != group.id } }
        else
          raise ArgumentError, "Evidence movement regrouped" if dependencies.any? { |version| active_groups_for(version).any? }
        end
        true
      end
    rescue ArgumentError, ActiveRecord::RecordNotFound, KeyError
      false
    end

    private

    def active_groups_for(version)
      FinancialDocuments::SourceReview::EconomicLinker.valid_current_versions(@household).select do |group|
        group.source_economic_memberships.any? { |member| member.source_review_version_id == version.id }
      end
    end

    def validate_current!(version)
      identity = version.source_account_identity_version
      raise ArgumentError, "Evidence source or account identity changed" unless version.source_review_head.approved_version_id == version.id && identity.source_account_review_head.approved_version_id == identity.id
      raise ArgumentError, "Only asset-account facts support reserved money" unless identity.source_tracked_account.account_basis == "asset"
      raise ArgumentError, "Evidence must be posted within the personal challenge window" unless version.posted_on&.between?(@enrollment.starts_on, @enrollment.ends_on) && version.posted_on <= @enrollment.local_today
    end

    def check_digest!(actual, expected)
      raise ArgumentError, "Evidence facts changed; review their current digest" unless actual == expected
    end

    def dependency(version)
      { "version_id" => version.id, "digest" => version.digest, "identity_version_id" => version.source_account_identity_version_id,
        "identity_digest" => version.source_account_identity_version.digest, "posted_on" => version.posted_on.iso8601 }
    end
  end
end
