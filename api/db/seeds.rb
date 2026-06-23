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

DEFAULT_ADMIN_EMAILS = [ "shimizutechnology@gmail.com" ].freeze

seed_admin_emails = [
  *DEFAULT_ADMIN_EMAILS,
  ENV.fetch("SEED_ADMIN_EMAIL", nil),
  *ENV.fetch("SEED_ADMIN_EMAILS", "").split(",")
].compact_blank.map { |email| email.strip.downcase }.uniq

seed_admin_emails.each do |email|
  user = User.find_or_initialize_by(email: email)
  user.clerk_id = "pending_#{SecureRandom.uuid}" if user.clerk_id.blank?
  user.first_name = "Household" if user.first_name.blank?
  user.last_name = "Admin" if user.last_name.blank?
  user.role = "admin"
  user.invitation_status = user.invitation_accepted? ? "accepted" : "pending"
  user.invited_at ||= Time.current
  user.save!
  puts "Seeded admin invite for #{user.email} (#{user.invitation_status})"
end
