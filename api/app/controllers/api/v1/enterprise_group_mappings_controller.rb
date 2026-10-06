module Api
  module V1
    class EnterpriseGroupMappingsController < EnterpriseBaseController
      def index
        render json: { group_mappings: enterprise_organization.enterprise_group_mappings.order(:id).map(&:as_api_json) }
      end

      def create
        mutate_mapping("group_mapping.created") do
          mapping = enterprise_organization.enterprise_group_mappings.create!(mapping_params)
          render json: { group_mapping: mapping.as_api_json }, status: :created
        end
      end

      def update
        mutate_mapping("group_mapping.updated") do
          mapping = enterprise_organization.enterprise_group_mappings.find(params[:id])
          mapping.update!(mapping_params)
          render json: { group_mapping: mapping.as_api_json }
        end
      end

      def destroy
        mutate_mapping("group_mapping.deleted") do
          enterprise_organization.enterprise_group_mappings.find(params[:id]).destroy!
          head :no_content
        end
      end

      private

      def mapping_params
        params.require(:group_mapping).permit(:workos_group_id, :cohort_id, :active)
      end

      def mutate_mapping(action)
        enterprise_admin!
        enterprise_organization.with_lock do
          yield
          enterprise_organization.enterprise_memberships.each { |membership| Enterprise::Enrollment.reconcile!(membership) }
          enterprise_audit!(action)
        end
      end
    end
  end
end
