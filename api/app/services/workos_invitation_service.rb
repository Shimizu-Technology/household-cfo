require "httparty"
require "uri"

class WorkosInvitationService
  class DeliveryError < StandardError; end
  MAX_PAGES = 10

  def self.send_invite(user:, invited_by:, &delivery)
    new(user: user, invited_by: invited_by, delivery: delivery).send_invite
  end

  def self.custom_delivery?
    ENV.fetch("WORKOS_INVITATION_EMAIL_DELIVERY", "native") == "custom"
  end

  def self.acceptance_url(destination, token)
    uri = URI.parse(destination.to_s)
    valid = uri.host.present? && uri.userinfo.nil? && uri.fragment.nil? &&
      (uri.scheme == "https" || (!Rails.env.production? && uri.scheme == "http" && %w[localhost 127.0.0.1].include?(uri.host)))
    raise DeliveryError, "The program sign-in destination is not configured correctly." unless valid
    destination_uri = uri.dup
    destination_uri.path = "/" unless destination_uri.path.in?([ "", "/", "/login", "/organization-access" ])
    destination_uri.query = destination_uri.query == "enterprise=1" ? "enterprise=1" : nil
    uri.path = "/login"
    uri.query = URI.encode_www_form(invitation_token: token, returnTo: destination_uri.to_s)
    uri.to_s
  rescue URI::InvalidURIError
    raise DeliveryError, "The program sign-in destination is not configured correctly."
  end

  def initialize(user:, invited_by:, delivery: nil)
    @user = user
    @invited_by = invited_by
    @delivery = delivery
  end

  def send_invite
    raise DeliveryError, "WorkOS authentication is not configured" unless WorkosAuth.configured?
    mode = ENV.fetch("WORKOS_INVITATION_EMAIL_DELIVERY", "native")
    raise DeliveryError, "WorkOS invitation delivery mode is invalid." unless mode.in?(%w[native custom])
    if mode == "custom" && (ENV["WORKOS_INVITATION_EMAILS_DISABLED"] != "true" || !@delivery)
      raise DeliveryError, "Custom invitation delivery requires verified WorkOS default-email suppression and a configured mail sender."
    end
    @user = User.find(@user.id)
    unless @user.invitation_status == "pending" && !@user.revoked?
      raise DeliveryError, "Only pending local invitations can be emailed."
    end
    invitation = pending_invitation
    if invitation
      @invitation_id = invitation.fetch("id")
      response = request(:post, "/user_management/invitations/#{@invitation_id}/resend")
    else
      payload = { email: @user.email }
      creator = @user.invited_by_user || @invited_by
      inviter_identity = creator&.authentication_identities&.find_by(provider: "workos", issuer: WorkosAuth.issuer)
      payload[:inviter_user_id] = inviter_identity.subject if inviter_identity
      response = request(:post, "/user_management/invitations", body: payload, recover_duplicate: true)
    end
    validate_invitation!(response)
    @invitation_id = response.fetch("id")
    if mode == "custom"
      delivered = @delivery.call(response.fetch("token"), @user)
      unless delivered.is_a?(Hash) && delivered[:sent] && delivered[:provider_message_id].present?
        raise DeliveryError, "The invitation email provider did not confirm delivery. Retry later."
      end
      return delivered.slice(:sent, :status, :provider, :provider_message_id, :error).merge(
        authentication_provider: "workos", native_invitation_id: @invitation_id)
    end
    result(sent: true)
  rescue DeliveryError => error
    result(sent: false, error: error.message)
  rescue ActiveRecord::ActiveRecordError
    result(sent: false, error: "The local invitation could not be verified. Reload before retrying.")
  end

  private

  def result(sent:, error: nil)
    # Tokens and acceptance URLs are deliberately absent from results and audit data.
    { sent: sent, status: sent ? "sent" : "failed", provider: "workos",
      provider_message_id: @invitation_id, error: error }
  end

  def pending_invitation
    stored_id = @user.invitation_email_provider_id.to_s
    unless valid_id?(stored_id)
      stored_id = @user.invitation_email_attempts.where(provider: "workos").order(id: :desc).pluck(:provider_message_id).find { |id| valid_id?(id.to_s) }
    end
    if stored_id.present?
      existing = request(:get, "/user_management/invitations/#{stored_id}", allow_missing: true)
      return existing if pending_for_user?(existing)
    end
    after = nil
    MAX_PAGES.times do
      page = request(:get, "/user_management/invitations", query: { email: @user.email, limit: 100 }.merge(after ? { after: after } : {}))
      rows = page["data"]
      raise DeliveryError, "WorkOS returned an invalid invitation list." unless rows.is_a?(Array)
      pending = rows.find { |row| pending_for_user?(row) }
      return pending if pending
      metadata = page["list_metadata"]
      raise DeliveryError, "WorkOS returned invalid invitation pagination." unless metadata.nil? || metadata.is_a?(Hash)
      cursor = metadata&.dig("after")
      return nil if rows.empty? || cursor.blank?
      raise DeliveryError, "WorkOS invitation pagination is unavailable." unless cursor.is_a?(String) && cursor != after
      after = cursor
    end
    raise DeliveryError, "WorkOS invitation lookup exceeded its safe limit. Retry later."
  end

  def pending_for_user?(invitation)
    invitation.is_a?(Hash) && valid_id?(invitation["id"]) && invitation["email"].to_s.strip.downcase == @user.email &&
      invitation["organization_id"].blank? && invitation["state"] == "pending" &&
      invitation["expires_at"].is_a?(String) && Time.iso8601(invitation["expires_at"]) > Time.current
  rescue ArgumentError
    false
  end

  def validate_invitation!(invitation)
    unless pending_for_user?(invitation) && invitation["token"].is_a?(String) && invitation["token"].bytesize.between?(1, 4096) && !invitation["token"].match?(/[[:space:][:cntrl:]]/)
      raise DeliveryError, "WorkOS did not confirm a usable invitation. Refresh its status before retrying."
    end
  end

  def valid_id?(id)
    id.is_a?(String) && id.match?(/\Ainvitation_[A-Za-z0-9]+\z/)
  end

  def request(method, path, query: {}, body: nil, allow_missing: false, recover_duplicate: false)
    options = { headers: { "Authorization" => "Bearer #{ENV.fetch('WORKOS_API_KEY')}", "Content-Type" => "application/json" },
      timeout: 5, open_timeout: 3, follow_redirects: false }
    options[:query] = query if query.any?
    options[:body] = JSON.generate(body) if body
    response = HTTParty.public_send(method, "#{WorkosAuth.api_origin}#{path}", **options)
    return nil if allow_missing && response.code == 404
    if recover_duplicate && response.code.in?([ 409, 422 ])
      existing = pending_invitation
      raise DeliveryError, "WorkOS could not create this invitation. Refresh its status before retrying." unless existing
      @invitation_id = existing.fetch("id")
      return request(:post, "/user_management/invitations/#{@invitation_id}/resend")
    end
    if response.code == 429
      raise DeliveryError, "WorkOS invitations are rate limited. Try again shortly."
    end
    raise DeliveryError, "WorkOS invitation service is unavailable (status #{response.code}). Retry later." unless response.success?
    data = response.parsed_response
    raise DeliveryError, "WorkOS returned an invalid invitation response." unless data.is_a?(Hash)
    data
  rescue HTTParty::Error, Timeout::Error, SocketError, SystemCallError, IOError, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Net::ProtocolError, OpenSSL::SSL::SSLError, JSON::ParserError
    raise DeliveryError, "WorkOS invitation delivery could not be confirmed. Refresh its status before retrying."
  end
end
