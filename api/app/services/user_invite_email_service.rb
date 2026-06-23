require "cgi"

class UserInviteEmailService
  BRAND_NAME = "Household CFO powered by VERA".freeze

  class << self
    def send_invite(user:, invited_by:)
      return skipped("RESEND_API_KEY is not configured") if ENV["RESEND_API_KEY"].blank?
      return skipped("MAILER_FROM_EMAIL or RESEND_FROM_EMAIL is not configured") if from_email.blank?

      response = Resend::Emails.send(
        {
          from: from_email,
          to: user.email,
          subject: "You're invited to Household CFO",
          html: invite_html(user: user, invited_by: invited_by, button_link: frontend_url, display_url: frontend_url),
          text: invite_text(user: user, invited_by: invited_by, button_link: frontend_url)
        }
      )

      Rails.logger.info("[InviteEmail] Sent invite to #{user.email} response=#{response.inspect}")
      {
        sent: true,
        status: "sent",
        provider_message_id: response_id(response),
        error: nil
      }
    rescue StandardError => e
      Rails.logger.error("[InviteEmail] Failed for #{user.email}: #{e.class} #{e.message}")
      {
        sent: false,
        status: "failed",
        provider_message_id: nil,
        error: e.message
      }
    end

    private

    def skipped(reason)
      Rails.logger.warn("[InviteEmail] #{reason}; skipping invite email")
      {
        sent: false,
        status: "skipped",
        provider_message_id: nil,
        error: reason
      }
    end

    def response_id(response)
      return response["id"] if response.respond_to?(:[]) && response["id"].present?
      return response[:id] if response.respond_to?(:[]) && response[:id].present?

      nil
    end

    def from_email
      ENV["RESEND_FROM_EMAIL"].presence || ENV["MAILER_FROM_EMAIL"].presence
    end

    def frontend_url
      ENV.fetch("FRONTEND_URL") do
        ENV.fetch("FRONTEND_URLS", "http://localhost:5173").split(",").first.strip
      end
    end

    def h(value)
      CGI.escapeHTML(value.to_s)
    end

    def invite_text(user:, invited_by:, button_link:)
      inviter = invited_by&.full_name.presence || invited_by&.email.presence || "A Household CFO admin"

      <<~TEXT.squish
        #{inviter} invited you to #{BRAND_NAME} as #{user.role}. Open #{button_link} and sign up or sign in using #{user.email}. If you were not expecting this invitation, you can ignore this email.
      TEXT
    end

    def invite_html(user:, invited_by:, button_link:, display_url:)
      inviter = h(invited_by&.full_name.presence || invited_by&.email.presence || "A Household CFO admin")
      role = h(user.role.to_s.titleize)
      invited_email = h(user.email)
      button_href = h(button_link)
      display_link = h(display_url)

      <<~HTML
        <!doctype html>
        <html>
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>Household CFO Invitation</title>
          </head>
          <body style="margin:0;padding:0;background-color:#f7f2ea;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Arial,sans-serif;-webkit-font-smoothing:antialiased;">
            <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background-color:#f7f2ea;">
              <tr>
                <td align="center" style="padding:40px 16px;">
                  <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="max-width:560px;background-color:#fffdf8;border:1px solid #e2d9cb;border-radius:18px;overflow:hidden;box-shadow:0 18px 54px rgba(47,38,28,0.10);">
                    <tr><td style="height:5px;background-color:#0f4c3a;font-size:0;line-height:0;">&nbsp;</td></tr>
                    <tr>
                      <td style="padding:34px 34px 0 34px;text-align:center;">
                        <p style="margin:0 0 10px 0;color:#0f4c3a;font-size:11px;letter-spacing:0.18em;text-transform:uppercase;font-weight:800;">Cohort invitation</p>
                        <h1 style="margin:0;color:#1f2421;font-family:Georgia,'Times New Roman',serif;font-size:30px;line-height:1.08;font-weight:700;">You're invited to Household CFO</h1>
                      </td>
                    </tr>
                    <tr>
                      <td style="padding:22px 34px 0 34px;text-align:center;">
                        <p style="margin:0;color:#706d66;font-size:15px;line-height:1.7;">
                          #{inviter} added you as <strong style="color:#1f2421;">#{role}</strong> in #{h(BRAND_NAME)}.
                        </p>
                      </td>
                    </tr>
                    <tr>
                      <td style="padding:22px 34px 0 34px;">
                        <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background-color:#e3efe9;border:1px solid #c7ddd1;border-radius:14px;">
                          <tr>
                            <td style="padding:18px;">
                              <p style="margin:0 0 6px 0;color:#0f4c3a;font-size:10px;letter-spacing:0.16em;text-transform:uppercase;font-weight:800;">Use this email</p>
                              <p style="margin:0;color:#1f2421;font-size:14px;line-height:1.65;">
                                Open the app and sign up or sign in with <strong>#{invited_email}</strong>. Household CFO will link your Clerk account to this invitation.
                              </p>
                            </td>
                          </tr>
                        </table>
                      </td>
                    </tr>
                    <tr>
                      <td align="center" style="padding:26px 34px 0 34px;">
                        <table role="presentation" cellspacing="0" cellpadding="0">
                          <tr>
                            <td style="border-radius:999px;background-color:#0f4c3a;">
                              <a href="#{button_href}" target="_blank" style="display:inline-block;padding:14px 30px;color:#ffffff;text-decoration:none;font-size:15px;font-weight:800;">Open Household CFO</a>
                            </td>
                          </tr>
                        </table>
                      </td>
                    </tr>
                    <tr>
                      <td style="padding:18px 34px 0 34px;text-align:center;">
                        <p style="margin:0 0 4px 0;color:#706d66;font-size:12px;">Or copy and paste this link into your browser:</p>
                        <p style="margin:0;color:#0f4c3a;font-size:12px;word-break:break-all;">#{display_link}</p>
                      </td>
                    </tr>
                    <tr>
                      <td style="padding:30px 34px 34px 34px;">
                        <table role="presentation" width="100%" cellspacing="0" cellpadding="0"><tr><td style="height:1px;background-color:#e2d9cb;font-size:0;">&nbsp;</td></tr></table>
                        <p style="margin:16px 0 0 0;color:#706d66;font-size:12px;line-height:1.65;text-align:center;">
                          If you were not expecting this invitation, you can ignore this email. This message does not include any financial data.
                        </p>
                      </td>
                    </tr>
                  </table>
                </td>
              </tr>
            </table>
          </body>
        </html>
      HTML
    end
  end
end
