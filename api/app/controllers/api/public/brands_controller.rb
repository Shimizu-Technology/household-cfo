# frozen_string_literal: true

module Api
  module Public
    class BrandsController < ApplicationController
      def show
        result = Branding::PublicResolver.new(hostname: params[:hostname].presence || request.host).call
        render json: {
          brand: result.config,
          source: result.source,
          available: result.available,
          workspace: result.workspace && {
            slug: result.workspace.slug
          },
          version: result.version && {
            number: result.version.version_number,
            digest: result.version.config_digest
          },
          primary_domain: result.primary_domain
        }, status: result.available ? :ok : :not_found
      end
    end
  end
end
