# This file should be idempotent. Do not seed real client financial data.
#
# To create a local invited admin for Clerk testing:
#   SEED_ADMIN_EMAIL=you@example.com bin/rails db:seed

seed_admin_email = ENV.fetch("SEED_ADMIN_EMAIL", nil)

if seed_admin_email.present?
  User.find_or_create_by!(email: seed_admin_email.downcase.strip) do |user|
    user.clerk_id = "pending_#{SecureRandom.uuid}"
    user.first_name = "Household"
    user.last_name = "Admin"
    user.role = "admin"
    user.invitation_status = "pending"
    user.invited_at = Time.current
  end
end
