# frozen_string_literal: true

module Api
  module V1
    module Admin
      class WorkspaceBrandLogosController < WorkspaceBrandConfigurationsController
        participant_rate_limit to: 20, within: 1.hour, name: "workspace_brand_logo_upload"

        def create
          authorize!(:edit)
          base_url = request.base_url
          base_url = base_url.sub(/\Ahttp:/, "https:") unless Rails.env.local?
          Branding::LogoUploader.new(configuration: configuration, actor: current_user, base_url: base_url).call(
            file: params[:file], expected_draft_revision: params[:draft_revision]
          )
          render_configuration
        rescue Branding::LogoImage::Invalid => error
          render json: { error: error.message, code: "brand_logo_invalid" }, status: :unprocessable_entity
        rescue Branding::LogoUploader::Conflict => error
          render json: { error: error.message, code: "brand_draft_conflict" }, status: :conflict
        rescue Branding::LogoUploader::Unavailable
          render json: { error: "Your logo could not be stored. Try again later.", code: "brand_logo_unavailable" }, status: :service_unavailable
        rescue ActiveRecord::RecordInvalid => error
          render_invalid(error.record)
        end
      end
    end
  end
end
