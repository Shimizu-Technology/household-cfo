module SetupHelp
  class Restart
    def initialize(household, user:, cohort_membership: nil, request_id: nil)
      @household, @user, @membership, @request_id = household, user, cohort_membership, request_id
    end

    def status(review_id: nil)
      @household.with_lock do
        Access.participant!(@household, user: @user, cohort_membership: @membership)
        owner = @household.household_memberships.exists?(user_id: @user.id, role: "owner")
        record = support_request if @request_id
        latest = if review_id
          authorize_owner!
          reviews.find(review_id)
        elsif owner
          reviews.order(id: :desc).first
        end
        # Reading the owner's receipt remains possible after an applied rollover.
        { available: owner && (record ? record.status == "ready" : Eligibility.new(@household).available?),
          owner_required: !owner, admin_required: false, household_id: @household.id, household_name: @household.name,
          financial_generation: @household.financial_generation, latest_review: latest && core.serialize(latest) }
      end
    end

    def preview
      @household.with_lock do
        HouseholdFinance::FinancialGenerationGuard.request!(@household)
        authorize_owner!
        review = if @request_id
          record = support_request
          raise Error, "Support is still reviewing this request. Nothing changed." unless record.status == "ready" && record.financial_restart_review
          Access.staff!(record, user: record.prepared_by_user, prepare: true)
          record.financial_restart_review
        else
          require_self_eligibility!
          core.create_review!(cohort_id: @membership&.cohort_id, purpose: "self_setup")
        end
        status.merge(review: core.serialize(review))
      end
    end

    def apply(review_id:, confirmation:, shared_household_acknowledged: false)
      @household.with_lock do
        authorize_owner!
        record = support_request if @request_id
        review = reviews.find(review_id)
        if record
          unless record.financial_restart_review_id == review.id && record.status.in?(%w[ready applied])
            raise Stale, "This prepared setup review changed. Ask support for a fresh review. Nothing changed."
          end
          Access.staff!(record, user: record.prepared_by_user, prepare: true)
        end
        return status(review_id: review.id).merge(review: core.serialize(review), setup_required: true) if review.status == "applied"
        require_self_eligibility! unless record
        core.apply_review!(review, confirmation: confirmation, shared_household_acknowledged: shared_household_acknowledged)
        if record
          record.update!(status: "applied")
          participant.audit!(record, "applied")
        end
        status(review_id: review.id).merge(review: core.serialize(review), setup_required: true)
      end
    end

    def cancel(review_id:)
      @household.with_lock do
        authorize_owner!
        review = reviews.find(review_id)
        if @request_id
          record = support_request
          unless record.financial_restart_review_id == review.id
            raise Stale, "This prepared setup review changed. Refresh the request before canceling. Nothing changed."
          end
          return participant.cancel_request(id: record.id, expected_lock_version: record.lock_version).then { status.merge(review: core.serialize(review.reload)) }
        end
        core.cancel_review!(review)
        status.merge(review: core.serialize(review))
      end
    end

    private
    def participant = Participant.new(@household, user: @user, cohort_membership: @membership)
    def core = HouseholdFinance::FinancialRestart::Core.new(@household, user: @user)
    def authorize_owner! = Access.participant!(@household, user: @user, cohort_membership: @membership, owner: true)
    def support_request = participant.own_request!(@request_id)
    def reviews
      scope = @household.financial_restart_reviews.where(requested_by_user: @user, cohort_id: @membership&.cohort_id)
      @request_id ? scope.where(purpose: "supported_setup", setup_support_request_id: support_request.id) : scope.where(purpose: "self_setup")
    end
    def require_self_eligibility!
      raise Error, "Your saved financial information needs a reviewed support request before starting again. Nothing changed." unless Eligibility.new(@household).available?
    end
  end
end
