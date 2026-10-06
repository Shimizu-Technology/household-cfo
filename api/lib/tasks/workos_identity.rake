namespace :auth do
  namespace :workos do
    desc "Verify an explicit local user/WorkOS mapping; APPLY=true writes it"
    task bind: :environment do
      WorkosIdentityMapping.bind!(user_id: ENV.fetch("USER_ID"), subject: ENV.fetch("WORKOS_USER_ID"),
        expected_clerk_id: ENV.fetch("EXPECTED_CLERK_ID"), dry_run: ENV["APPLY"] != "true")
      puts ENV["APPLY"] == "true" ? "WorkOS identity mapping applied" : "WorkOS identity mapping verified; set APPLY=true to write"
    end

    desc "Report accepted accounts still requiring WorkOS mapping for this issuer"
    task readiness: :environment do
      raise WorkosAuth::Unavailable, "WorkOS authentication is not configured" unless WorkosAuth.configured?
      mapped_ids = AuthenticationIdentity.where(provider: "workos", issuer: WorkosAuth.issuer).select(:user_id)
      unmapped = User.where(invitation_status: "accepted").where.not(id: mapped_ids)
      puts "Accepted accounts without a WorkOS identity: #{unmapped.count}"
      puts "Local user IDs: #{unmapped.order(:id).pluck(:id).join(', ')}"
      abort "WorkOS cutover is not ready" if unmapped.exists?
    end
  end
end
