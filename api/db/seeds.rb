# This file should be idempotent. Do not seed real client financial data.
#
# Local/deployment bootstrap admins are invite records only. The user still signs
# in through Clerk with the same email, then the API links their Clerk ID.
#
# Always seeded for Household CFO ownership:
#   shimizutechnology@gmail.com
#
# Additional options:
#   SEED_ADMIN_EMAIL=you@example.com bin/rails db:seed
#   SEED_ADMIN_EMAILS=you@example.com,partner@example.com bin/rails db:seed

seed_admin_emails = [
  "shimizutechnology@gmail.com",
  ENV.fetch("SEED_ADMIN_EMAIL", nil),
  *ENV.fetch("SEED_ADMIN_EMAILS", "").split(",")
].compact_blank.map { |email| email.strip.downcase }.uniq

seed_admin_emails.each do |email|
  user = User.find_or_initialize_by(email: email)
  new_invite = user.new_record?

  if new_invite
    user.assign_attributes(
      clerk_id: "pending_#{SecureRandom.uuid}",
      first_name: "Household",
      last_name: "Admin",
      role: "admin",
      invitation_status: "pending",
      invited_at: Time.current
    )
  else
    # Keep seeds idempotent: fill missing bootstrap fields, but do not undo an
    # intentional admin UI role/status change such as demotion or revocation.
    user.clerk_id = "pending_#{SecureRandom.uuid}" if user.clerk_id.blank?
    user.first_name = "Household" if user.first_name.blank?
    user.last_name = "Admin" if user.last_name.blank?
    user.invited_at ||= Time.current if user.invitation_pending?
  end

  user.save!
  puts "#{new_invite ? 'Seeded' : 'Verified'} admin invite for #{user.email} (#{user.role}, #{user.invitation_status})"
end
