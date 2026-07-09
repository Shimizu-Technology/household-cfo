# frozen_string_literal: true

module Api
  module V1
    class MiaTranscriptionsController < BaseController
      before_action :authenticate_user!
      before_action :require_existing_household!

      MAX_AUDIO_BYTES = 12.megabytes
      ALLOWED_EXTENSIONS = %w[.webm .m4a .mp3 .wav .ogg .flac .mp4].freeze
      ALLOWED_CONTENT_TYPES = %w[
        audio/webm video/webm audio/mp4 audio/m4a audio/mpeg audio/mp3 audio/wav audio/x-wav audio/ogg audio/flac application/octet-stream
      ].freeze

      def create
        file = params[:audio] || params[:file]
        return render json: { errors: [ "No audio uploaded" ] }, status: :unprocessable_entity unless valid_upload_param?(file)

        validation_error = upload_validation_error(file)
        return render json: { errors: [ validation_error ] }, status: :unprocessable_entity if validation_error

        result = HouseholdFinance::VoiceTranscriber.new(file: file).call
        return render json: { transcript: result.transcript } if result.success?

        status = result.error == "Voice transcription is not configured." ? :service_unavailable : :unprocessable_entity
        render json: { errors: [ result.error ] }, status: status
      end

      private

      def require_existing_household!
        return if current_user.household_memberships.exists?

        render json: { errors: [ "Open a real workspace before using voice input." ] }, status: :forbidden
      end

      def valid_upload_param?(file)
        file.respond_to?(:tempfile) && file.respond_to?(:original_filename)
      end

      def upload_validation_error(file)
        filename = file.original_filename.to_s
        extension = File.extname(filename).downcase
        return "Unsupported audio type. Record WEBM audio or upload M4A, MP3, WAV, OGG, or FLAC." unless extension.in?(ALLOWED_EXTENSIONS)
        return "Audio file is empty" if File.zero?(file.tempfile.path)
        return "Audio file is too large (max #{MAX_AUDIO_BYTES / 1.megabyte} MB)" if File.size(file.tempfile.path) > MAX_AUDIO_BYTES

        content_type = normalized_content_type(file)
        return "Unsupported audio type. Record WEBM audio or upload M4A, MP3, WAV, OGG, or FLAC." unless content_type.in?(ALLOWED_CONTENT_TYPES)

        nil
      end

      def normalized_content_type(file)
        file.content_type.to_s.split(";").first.to_s.downcase.presence || "application/octet-stream"
      end
    end
  end
end
