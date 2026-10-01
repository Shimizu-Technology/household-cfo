# frozen_string_literal: true

module Api
  module V1
    module Admin
      class CoachContentPacksController < BaseController
        before_action :authenticate_user!
        before_action :require_staff!
        rescue_from ActiveRecord::RecordNotFound, with: :not_found

        def index
          packs = policy.visible_packs.includes(
            current_published_version: { entries: :coach_content_item_version },
            versions: { entries: :coach_content_item_version },
            draft_entries: { coach_content_item_version: { coach_content_item: :current_approved_version } }
          ).order(updated_at: :desc)
          render json: { packs: packs.map { |pack| serializer.pack(pack) } }
        end

        def create
          pack = CoachContentPack.transaction do
            created_pack = CoachContentPack.create!(pack_params.merge(created_by_user: current_user))
            replace_items(created_pack)
            created_pack
          end
          render json: { pack: serializer.pack(pack.reload) }, status: :created
        rescue ActiveRecord::RecordInvalid => error
          invalid(error.record)
        rescue ArgumentError => error
          invalid_message(error.message)
        end

        def update
          pack = policy.editable_packs.find(params[:id])
          CoachContentPack.transaction do
            pack.with_lock do
              return conflict unless Integer(params.dig(:pack, :draft_revision), exception: false) == pack.draft_revision
              pack.update!(pack_params.except(:scope))
            end
            replace_items(pack) if params.require(:pack).key?(:item_version_ids)
          end
          render json: { pack: serializer.pack(pack.reload) }
        rescue ActiveRecord::RecordInvalid => error
          invalid(error.record)
        rescue ArgumentError => error
          invalid_message(error.message)
        end

        def publish
          pack = policy.editable_packs.find(params[:id])
          version = pack.publish!(
            actor: current_user,
            expected_draft_revision: params.dig(:pack, :draft_revision),
            expected_draft_manifest_digest: params.dig(:pack, :draft_manifest_digest),
            expected_current_version_id: params.dig(:pack, :expected_published_version_id)
          )
          render json: { pack: serializer.pack(pack.reload), published_version: serializer.pack_version(version) }
        rescue CoachContentPack::PublicationConflict
          conflict
        rescue ArgumentError => error
          invalid_message(error.message)
        end

        def destroy
          pack = policy.editable_packs.find(params[:id])
          pack.update!(archived_at: Time.current)
          render json: { pack: serializer.pack(pack.reload) }
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

        def pack_params
          params.require(:pack).permit(:name, :description, :scope, :pack_kind).to_h.symbolize_keys
        end

        def replace_items(pack)
          ids = Array(params.dig(:pack, :item_version_ids)).map(&:to_i).select(&:positive?)
          retained_ids = pack.draft_entries.where(coach_content_item_version_id: ids).pluck(:coach_content_item_version_id)
          new_ids = ids - retained_ids
          retained = CoachContentItemVersion.where(id: retained_ids)
          selectable = CoachContentItemVersion.where(
            id: new_ids,
            coach_content_item_id: policy.visible_items.where(archived_at: nil).select(:id)
          )
          versions = retained.or(selectable).includes(:coach_content_item).index_by(&:id)
          raise ArgumentError, "One or more approved items are unavailable" unless versions.length == ids.uniq.length

          pack.replace_draft_item_versions!(ids.uniq.map { |id| versions.fetch(id) }, actor: current_user)
        end

        def invalid(record)
          invalid_message(record.errors.full_messages.first, errors: record.errors.full_messages)
        end

        def invalid_message(message, errors: [ message ])
          render json: { error: message, errors: errors, code: "content_pack_invalid" }, status: :unprocessable_entity
        end

        def conflict
          render json: { error: "The content pack changed; reload it before saving.", code: "content_pack_conflict" }, status: :conflict
        end

        def not_found
          render json: { error: "Content pack not found.", code: "content_pack_not_found" }, status: :not_found
        end
      end
    end
  end
end
