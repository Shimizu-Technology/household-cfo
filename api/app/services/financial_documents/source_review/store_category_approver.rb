module FinancialDocuments
  module SourceReview
    # One explicit store answer. All saves stay in the caller's locked transaction.
    class StoreCategoryApprover
      def self.call(domain, revision, input, membership: nil)
        rows = Array(input[:store_lines]).map { |row| row.to_h.deep_symbolize_keys }
        raise ArgumentError, "Choose up to 1000 lines" unless rows.length.between?(1, 1000)
        raise ArgumentError, "Choose each line once" unless rows.map { |row| row[:event_id] }.uniq.length == rows.length
        raise ArgumentError, "Choose a category" unless rows.all? { |row| row[:decision] == "edited" && row[:edit].is_a?(Hash) && row[:edit].keys == [ :category_id ] && row[:expected_head].present? }
        raise ArgumentError, "Choose one category for this store" unless rows.map { |row| row[:edit][:category_id] }.uniq.one?
        category_id = rows.first.dig(:edit, :category_id)
        raise ArgumentError, "Choose an active category" unless category_id.is_a?(Integer) && domain.household.budget_categories.active.exists?(id: category_id)
        groups = rows.group_by { |row| row.fetch(:revision_id) }
        raise ArgumentError, "Include this statement" unless groups.key?(revision.id)
        plans = groups.to_h do |id, entries|
          other = FinancialExtractionRevision.where(household: domain.household).find(id)
          document = other.financial_document_import || raise(ActiveRecord::RecordNotFound)
          HouseholdFinance::FinancialGenerationGuard.source!(document, locked_household: domain.household)
          raise Domain::StaleReview, "This statement changed. Refresh and try again." unless document.financial_extraction_revisions.order(revision_number: :desc, id: :desc).first.id == id
          [ id, [ other, ParticipantPlan.new(domain.household, other), entries ] ]
        end
        lines = plans.values.flat_map do |_, plan, entries|
          entries.map do |entry|
            line = plan.line_for(entry[:event_id]) || raise(ActiveRecord::RecordNotFound)
            raise Domain::StaleReview, "This line has a pending correction. Review it individually." if plan.review_heads[line.event.id]&.source_review_drafts&.any? { |draft| draft.status == "pending" }
            saved = plan.review_heads[line.event.id]&.approved_version
            retrying = line.done && saved&.disposition == "include" && saved.expense? && saved.budget_category_id == entry[:edit][:category_id]
            unless retrying || (!line.done && line.kind.in?(%i[no_category suggested_category still_category]))
              raise Domain::StaleReview, "This line needs its own answer. Refresh and try again."
            end
            line
          end
        end
        raise ArgumentError, "Choose one store" unless lines.map { |line| MerchantNormalizer.call(line.merchant).to_s.downcase.squish }.uniq.one?
        counts = Hash.new(0)
        plans.each_value do |other, _plan, entries|
          entries.each_slice(LineApprover::MAX_LINES).with_index do |page, page_index|
            prepared = page.map do |entry|
              entry.except(:revision_id).merge(edit: { kind: "spending", category_id: entry[:edit][:category_id] })
            end
            options = other.id == revision.id ? input.slice(:coverage_answer, :expected_coverage_id) : {}
            options = options.merge(input.slice(:accounts)) if other.id == revision.id && page_index.zero?
            result = LineApprover.new(domain, other, { lines: prepared }.merge(options), cohort_membership: membership).call
            result.each { |key, value| counts[key] += value if value.is_a?(Integer) }
          end
        end
        counts
      end
    end
  end
end
