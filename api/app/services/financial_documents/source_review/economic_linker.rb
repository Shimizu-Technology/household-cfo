module FinancialDocuments
  module SourceReview
    class EconomicLinker
      def self.current_versions(household)
        SourceEconomicGroupVersion.where(household: household).joins(:source_economic_group)
          .where("source_economic_groups.approved_version_id = source_economic_group_versions.id")
          .includes(source_economic_memberships: { source_review_version: [ :source_review_head, { source_account_identity_version: :source_account_review_head } ] })
      end

      def self.valid_current_versions(household)
        current_versions(household).select do |group|
          group.source_economic_memberships.all? do |member|
            version = member.source_review_version
            version.source_review_head.approved_version_id == version.id && version.source_account_identity_version.source_account_review_head.approved_version_id == version.source_account_identity_version_id
          end
        end
      end

      def self.active_memberships(household)
        valid_current_versions(household).flat_map { |group| group.source_economic_memberships.to_a }
      end

      def initialize(domain, input)
        @domain, @input = domain, input
      end

      def call
        rows = input[:members].map { |member| [ member, domain.versions.find(member[:source_review_version_id]) ] }
        rows.map(&:last).map(&:source_review_head).sort_by(&:id).each(&:lock!)
        rows.each do |_member, version|
          raise Domain::StaleReview, "A linked source fact changed" unless version.source_review_head.reload.approved_version_id == version.id && version.disposition == "include"
          domain.current_identity!(version.financial_source_event, version.source_account_identity_version_id)
        end
        group = input[:group_id] ? domain.groups.lock.find(input[:group_id]) : SourceEconomicGroup.create!(household: domain.household)
        unless group.approved_version_id == input[:base_version_id] && group.lock_version == input[:base_lock_version]
          raise Domain::StaleReview, "The economic link changed. Refresh it; nothing changed."
        end
        validate_shape!(rows)
        existing = self.class.active_memberships(domain.household).reject { |member| member.source_economic_group_version.source_economic_group_id == group.id }
        rows.each do |member, version|
          bucket = allocation_bucket(member[:role])
          used = existing.select { |other| other.source_review_version_id == version.id && allocation_bucket(other.role) == bucket }.sum(&:allocation_cents)
          ceiling = bucket == "consumption_refund" ? version.purchase_amount_cents : version.signed_amount_cents&.abs
          raise ArgumentError, "This movement or purchase is already allocated beyond its reviewed amount" unless ceiling && used + member[:allocation_cents] <= ceiling
        end
        approved = group.source_economic_group_versions.create!(household: domain.household, kind: input[:kind],
          version_number: group.source_economic_group_versions.maximum(:version_number).to_i + 1, supersedes_id: group.approved_version_id,
          approved_by_user: domain.user, reason: input[:reason], digest: domain.digest(input))
        input[:members].each { |member| approved.source_economic_memberships.create!(member.merge(household: domain.household)) }
        group.update!(approved_version: approved)
        approved
      end

      private

      attr_reader :domain, :input

      def allocation_bucket(role)
        role == "original_purchase" ? "consumption_refund" : "account_flow"
      end

      def validate_shape!(rows)
        case input[:kind]
        when "transfer"
          valid = rows.all? { |member, version| member[:role] == "movement" && version.event_type.in?(%w[transfer debt_payment]) } &&
            rows.map { |_member, version| version.source_tracked_account.id }.uniq.length >= 2 &&
            rows.sum { |member, version| version.signed_amount_cents.positive? ? member[:allocation_cents] : -member[:allocation_cents] }.zero?
          raise ArgumentError, "A transfer needs confirmed opposing movements on distinct reviewed accounts with equal allocations" unless valid
        when "purchase_funding"
          purchases = rows.select { |member, version| member[:role] == "purchase" && version.expense? && version.event_type == "purchase" }
          valid = purchases.one? && rows.reject { |row| row == purchases.first }.all? { |member, version| member[:role] == "funding" && version.event_type == "transfer" && version.signed_amount_cents.negative? } &&
            rows.all? { |_member, version| version.signed_amount_cents.negative? } &&
            rows.reject { |row| row == purchases.first }.all? { |_member, version| version.source_tracked_account.id != purchases.first.last.source_tracked_account.id } &&
            rows.sum { |member, _version| member[:allocation_cents] } == purchases.first.last.purchase_amount_cents &&
            purchases.first.first[:allocation_cents] == purchases.first.last.signed_amount_cents.abs
          raise ArgumentError, "Link exactly one full purchase to its reviewed local and bank funding legs" unless valid
        when "refund"
          purchase = rows.select { |member, version| member[:role] == "original_purchase" && version.expense? }
          refund = rows.select { |member, version| member[:role] == "refund" && version.event_type == "refund" && version.signed_amount_cents.positive? }
          raise ArgumentError, "A refund link needs one purchase and one equal reviewed refund allocation" unless rows.length == 2 && purchase.one? && refund.one? && purchase.first.first[:allocation_cents] == refund.first.first[:allocation_cents]
        else raise ArgumentError, "Unsupported economic link kind"
        end
      end
    end
  end
end
