# frozen_string_literal: true

module Api
  module V1
    module Admin
      class CoachContentItemsController < BaseController
        before_action :authenticate_user!
        before_action :require_staff!
        rescue_from ActiveRecord::RecordNotFound, with: :not_found

        def index
          items = policy.visible_items.includes(
            :current_approved_version,
            :versions,
            draft_source_provenance: [ :coach_content_source, :coach_content_source_attempt, :coach_content_source_candidate ]
          ).order(updated_at: :desc)
          render json: { items: items.map { |item| serializer.item(item) } }
        end

        def create
          attributes = item_params
          return require_selected_coach_workspace! if attributes[:scope] != "platform" && coach_workspace_for_policy.nil?

          item = CoachContentItem.create!(attributes.merge(
            created_by_user: current_user,
            coach_workspace: attributes[:scope] == "platform" ? nil : current_coach_workspace
          ))
          render json: { item: serializer.item(item) }, status: :created
        rescue ActiveRecord::RecordInvalid => error
          invalid(error.record)
        end

        def update
          item = policy.editable_items.find(params[:id])
          item.with_lock do
            return conflict("The content item changed; reload it before saving.") unless Integer(params.dig(:item, :draft_revision), exception: false) == item.draft_revision
            item.update!(item_params.except(:scope))
          end
          render json: { item: serializer.item(item.reload) }
        rescue ActiveRecord::RecordInvalid => error
          invalid(error.record)
        end

        def approve
          item = policy.reviewable_items.find(params[:id])
          version = item.approve!(
            actor: current_user,
            expected_draft_revision: params.dig(:item, :draft_revision),
            expected_draft_digest: params.dig(:item, :draft_digest)
          )
          render json: { item: serializer.item(item.reload), approved_version: serializer.item_version(version) }
        rescue CoachContentItem::ApprovalConflict => error
          conflict(error.message)
        rescue Mia::ContentSafetyValidator::UnsafeContent => error
          render json: { error: error.message, code: error.code }, status: :unprocessable_entity
        rescue ArgumentError => error
          render json: { error: error.message, code: "content_approval_invalid" }, status: :unprocessable_entity
        end

        def destroy
          item = policy.editable_items.find(params[:id])
          item.update!(archived_at: Time.current)
          render json: { item: serializer.item(item.reload) }
        rescue ActiveRecord::RecordInvalid => error
          invalid(error.record)
        end

        private

        def policy
          @policy ||= Mia::ContentLibraryPolicy.new(current_user, workspace: coach_workspace_for_policy)
        end

        def serializer
          @serializer ||= Mia::ContentLibrarySerializer.new(policy: policy)
        end

        def item_params
          permitted = params.require(:item).permit(:title, :scope, :kind, :draft_content, :always_on).to_h.symbolize_keys
          permitted[:draft_always_on] = permitted.delete(:always_on) if permitted.key?(:always_on)
          permitted
        end

        def invalid(record)
          render json: { error: record.errors.full_messages.first, errors: record.errors.full_messages, code: "content_item_invalid" }, status: :unprocessable_entity
        end

        def conflict(message)
          render json: { error: message, code: "content_item_conflict" }, status: :conflict
        end

        def not_found
          render json: { error: "Content item not found.", code: "content_item_not_found" }, status: :not_found
        end
      end
    end
  end
end
