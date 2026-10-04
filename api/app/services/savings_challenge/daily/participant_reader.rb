module SavingsChallenge
  module Daily
    # Every query reauthorizes the participant; the privacy erasure exception
    # intentionally grants no route through this reader.
    class ParticipantReader
      COLLECTIONS = {
        purchases: SavingsDailyPurchase, purchase_drafts: SavingsDailyPurchaseDraft, purchase_versions: SavingsDailyPurchaseVersion,
        reflections: SavingsDailyReflection, reflection_versions: SavingsDailyReflectionVersion,
        check_ins: SavingsDailyCheckIn, check_in_versions: SavingsDailyCheckInVersion,
        checkpoints: SavingsCheckpoint, checkpoint_drafts: SavingsCheckpointDraft, checkpoint_versions: SavingsCheckpointVersion
      }.freeze

      def initialize(enrollment, user:)
        @enrollment, @user = enrollment, user
      end

      def page(collection, limit: 20, after_id: nil, parent_id: nil)
        ReadPolicy.call!(@enrollment, user: @user)
        model = COLLECTIONS.fetch(collection) { raise ArgumentError, "Unknown private daily collection" }
        limit = SavingsChallenge::Inputs.integer!(limit, minimum: 1, maximum: 100)
        after_id = SavingsChallenge::Inputs.id!(after_id, nullable: true)
        parent_id = SavingsChallenge::Inputs.id!(parent_id, nullable: true)
        scope = model.where(savings_enrollment: @enrollment)
        if parent_id
          parent = case collection
          when :purchase_drafts, :purchase_versions then :savings_daily_purchase_id
          when :reflections then :savings_daily_purchase_id
          when :reflection_versions then :savings_daily_reflection_id
          when :check_in_versions then :savings_daily_check_in_id
          when :checkpoint_drafts, :checkpoint_versions then :savings_checkpoint_id
          else raise ArgumentError, "This private collection does not accept a parent filter"
          end
          scope = scope.where(parent => parent_id)
        end
        scope = scope.where("id > ?", after_id) if after_id
        rows = scope.order(:id).limit(limit + 1).to_a
        { records: rows.first(limit), next_cursor: rows.length > limit ? rows[limit - 1].id : nil }
      end

      def find(collection, id:)
        ReadPolicy.call!(@enrollment, user: @user)
        COLLECTIONS.fetch(collection).where(savings_enrollment: @enrollment).find(SavingsChallenge::Inputs.id!(id))
      end
    end
  end
end
