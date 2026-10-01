# frozen_string_literal: true

module Api
  module V1
    module Admin
      class CoachContentItemsController < BaseController
        before_action :authenticate_user!
        before_action :require_staff!
        rescue_from ActiveRecord::RecordNotFound, with: :not_found

        def index
          render json: { items: policy.visible_items.includes(:current_approved_version, :versions).order(updated_at: :desc).map { |item| serializer.item(item) } }
        end

        def create
          item = CoachContentItem.create!(item_params.merge(created_by_user: current_user))
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
          item = policy.editable_items.find(params[:id])
          version = item.approve!(actor: current_user)
          render json: { item: serializer.item(item.reload), approved_version: serializer.item_version(version) }
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
          @policy ||= Mia::ContentLibraryPolicy.new(current_user)
        end

        def serializer
          @serializer ||= Mia::ContentLibrarySerializer.new(policy: policy)
        end

        def item_params
          params.require(:item).permit(:title, :scope, :kind, :draft_content).to_h.symbolize_keys
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
