# frozen_string_literal: true

module Api
  module Public
    class BrandsController < ApplicationController
      def show
        response.headers["Cache-Control"] = "no-store"
        result = Branding::PublicResolver.new(hostname: requested_hostname).call
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

      private

      def requested_hostname
        requested = Branding::Hostname.normalize(params[:hostname].presence || request.host)
        origin = request.headers["Origin"].presence
        return requested unless origin

        origin_hostname = Branding::Hostname.from_origin(origin)
        requested if origin_hostname.present? && origin_hostname == requested
      end
    end
  end
end
