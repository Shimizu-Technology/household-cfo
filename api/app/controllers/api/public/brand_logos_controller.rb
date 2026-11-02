# frozen_string_literal: true

module Api
  module Public
    # Logos are public brand assets. The bucket stays private; an unguessable,
    # signed application URL is the only read capability exposed to browsers.
    class BrandLogosController < ApplicationController
      def show
        key = Branding::LogoAsset.key_from_token(params[:id])
        return head :not_found unless key

        url = S3Service.presigned_url(key, filename: "program-logo.png", disposition: :inline)
        return head :service_unavailable unless url

        response.headers["Cache-Control"] = "no-store"
        response.headers["X-Content-Type-Options"] = "nosniff"
        redirect_to url, allow_other_host: true
      rescue S3Service::MissingConfigurationError, Aws::Errors::ServiceError, Seahorse::Client::NetworkingError
        head :service_unavailable
      end
    end
  end
end
