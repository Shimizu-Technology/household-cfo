require "digest"

module HouseholdFinance
  module FinancialRestart
    class Flow
      Error = Class.new(ArgumentError)
      StaleReview = Class.new(Error)
      OwnerRequired = Class.new(Error)
      AdminRequired = Class.new(Error)
      def initialize(household, user:, cohort_membership: nil)
        @household, @user, @membership = household, user, cohort_membership
      end

      def status(review_id: nil)
        ChallengePrivacy::PrivateFinanceAccess.authorize!(household, user: user)
        actor = User.find_by(id: user.id)
        owner = household.household_memberships.exists?(user_id: user.id, role: "owner")
        available = actor&.admin? && !actor.revoked? && owner
        if review_id
          authorize!
          latest = household.financial_restart_reviews.where(requested_by_user: user, cohort_id: cohort_id, purpose: "admin_test").find(review_id)
        elsif available
          latest = household.financial_restart_reviews.where(requested_by_user: user, cohort_id: cohort_id, purpose: "admin_test").order(id: :desc).first
        end
        { available: !!available, admin_required: !actor&.admin?, owner_required: !owner, financial_generation: household.reload.financial_generation,
          household_id: household.id, household_name: household.name, latest_review: latest && serialize(latest) }
      end

      def preview
        household.with_lock do
          FinancialGenerationGuard.request!(household)
          authorize!
          review = core.create_review!(cohort_id: cohort_id, purpose: "admin_test")
          status.merge(review: serialize(review))
        end
      end

      def apply(review_id:, confirmation:, shared_household_acknowledged: false)
        household.with_lock do
          authorize!
          review = household.financial_restart_reviews.where(requested_by_user: user, cohort_id: cohort_id, purpose: "admin_test").find(review_id)
          return status.merge(review: serialize(review), setup_required: true) if review.status == "applied"
          core.apply_review!(review, confirmation: confirmation,
            shared_household_acknowledged: ActiveModel::Type::Boolean.new.cast(shared_household_acknowledged))
          status.merge(review: serialize(review), setup_required: true)
        end
      end

      def cancel(review_id:)
        household.with_lock do
          authorize!
          review = household.financial_restart_reviews.where(requested_by_user: user, cohort_id: cohort_id, purpose: "admin_test").find(review_id)
          review.update!(status: "canceled") if review.status == "pending"
          status.merge(review: serialize(review))
        end
      end

      private

      attr_reader :household, :user, :membership
      def cohort_id = membership&.cohort_id
      def shared_member_count = household.household_memberships.where.not(user_id: user.id).count

      def authorize!
        actor = User.lock.find_by(id: user.id)
        raise OwnerRequired, "This account no longer has permission to restart financial records. Nothing changed." unless actor && !actor.revoked?
        raise AdminRequired, "Starting over is an administrator testing tool. Update individual records through Mia or My Money instead. Nothing changed." unless actor.admin?
        raise OwnerRequired, "Only an administrator who owns this household can reset its test financial picture. Nothing changed." unless household.household_memberships.exists?(user_id: user.id, role: "owner")
        selected = ::Mia::EffectiveCohortResolver.new(user: user, role: "participant", requested_cohort_id: cohort_id).call if cohort_id
        if selected&.cohort&.savings_challenge_enabled
          SavingsChallenge::AccessPolicy.new(household: household, user: user, cohort: selected.cohort).call!
        elsif selected.nil? && ChallengePrivacy::PrivateFinanceAccess.pilot_household?(household)
          raise OwnerRequired, "Choose your current coaching program before reviewing a financial restart. Nothing changed."
        end
        ChallengePrivacy::PrivateFinanceAccess.authorize!(household, user: user)
      end

      def core = Core.new(household, user: user)
      def serialize(review) = core.serialize(review)
    end
  end
end
