# frozen_string_literal: true

require "cgi"

module CoachWorkspaces
  class CollaboratorInviteEmail
    def self.send_invite(user:, workspace:, role:, invited_by:, sign_in_url:, requested:)
      provider = AuthenticationProvider.public_provider if requested
      user = User.find(user.id) if provider == "workos"
      result = if !requested
        { sent: false, status: "skipped", provider_message_id: nil }
      elsif provider == "workos" && user.invitation_pending?
        if WorkosInvitationService.custom_delivery? && (ENV["RESEND_API_KEY"].blank? || (ENV["RESEND_FROM_EMAIL"].blank? && ENV["MAILER_FROM_EMAIL"].blank?))
          raise WorkosInvitationService::DeliveryError, "The invitation mail sender is not configured."
        end
        WorkosInvitationService.acceptance_url(sign_in_url, "validation") if WorkosInvitationService.custom_delivery?
        WorkosInvitationService.send_invite(user: user, invited_by: invited_by) do |token, recipient|
          link = WorkosInvitationService.acceptance_url(sign_in_url, token)
          text = "#{invited_by.full_name} invited you to collaborate in #{workspace.name} as #{role}. Open #{link} and sign up or sign in using #{recipient.email}. This invitation does not share any participant's financial records."
          begin
            response = Resend::Emails.send({ from: ENV["RESEND_FROM_EMAIL"].presence || ENV["MAILER_FROM_EMAIL"], to: recipient.email,
              subject: "Your collaborator access to #{workspace.name}", text: text,
              html: "<p>#{CGI.escapeHTML(invited_by.full_name)} invited you to #{CGI.escapeHTML(workspace.name)} as #{CGI.escapeHTML(role)}.</p><p><a href=\"#{CGI.escapeHTML(link)}\">Open your coaching workspace</a></p>" })
          rescue StandardError
            raise WorkosInvitationService::DeliveryError, "The invitation email provider could not confirm delivery. Retry later."
          end
          id = response.respond_to?(:[]) ? (response["id"].presence || response[:id].presence) : nil
          { sent: id.present?, status: id.present? ? "sent" : "failed", provider: "resend", provider_message_id: id, error: nil }
        end
      elsif ENV["RESEND_API_KEY"].blank? || (ENV["RESEND_FROM_EMAIL"].blank? && ENV["MAILER_FROM_EMAIL"].blank?) || sign_in_url.blank?
        { sent: false, status: "failed", provider_message_id: nil }
      else
        text = "#{invited_by.full_name} invited you to collaborate in #{workspace.name} as #{role}. Open #{sign_in_url} and sign up or sign in using #{user.email}. This invitation does not share any participant's financial records."
        response = Resend::Emails.send({
          from: ENV["RESEND_FROM_EMAIL"].presence || ENV["MAILER_FROM_EMAIL"], to: user.email,
          subject: "Your collaborator access to #{workspace.name}", text: text,
          html: "<p>#{CGI.escapeHTML(text)}</p><p><a href=\"#{CGI.escapeHTML(sign_in_url)}\">Open your coaching workspace</a></p>"
        })
        provider_id = response.respond_to?(:[]) ? (response["id"].presence || response[:id].presence) : nil
        { sent: provider_id.present?, status: provider_id.present? ? "sent" : "failed", provider: "resend", provider_message_id: provider_id }
      end
      record_attempt(user, invited_by, result)
      result
    rescue WorkosInvitationService::DeliveryError, AuthenticationProvider::ConfigurationError => error
      result = { sent: false, status: "failed", provider: provider || "unconfigured", provider_message_id: nil, error: error.message }
      begin
        record_attempt(user, invited_by, result)
      rescue ActiveRecord::ActiveRecordError
        Rails.logger.warn("[CollaboratorInviteEmail] Failed to record delivery failure user_id=#{user.id}")
      end
      result
    rescue StandardError => error
      Rails.logger.warn("[CollaboratorInviteEmail] request failed user_id=#{user.id} workspace_id=#{workspace.id} error=#{error.class}")
      { sent: false, status: "failed", provider_message_id: nil }
    end

    def self.record_attempt(user, actor, result)
      user.invitation_email_attempts.create!(sent_by_user: actor, status: result.fetch(:status), provider: result[:provider].presence || "resend",
        provider_message_id: result[:provider_message_id], error: result[:error], attempted_at: Time.current,
        sent_at: result[:sent] ? Time.current : nil)
    end
    private_class_method :record_attempt
  end
end
