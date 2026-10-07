module Enterprise
  class Enrollment
    def self.allowed_cohort_ids(membership)
      return [] unless membership.enterprise_organization.directory_id.present? && membership.enterprise_organization.directory_state == "linked"
      directory_user_ids = membership.enterprise_directory_users.where(state: "active").select(:id)
      group_ids = EnterpriseDirectoryGroupMembership.where(enterprise_directory_user_id: directory_user_ids, active: true).select(:workos_group_id)
      membership.enterprise_organization.enterprise_group_mappings.where(active: true, workos_group_id: group_ids).pluck(:cohort_id).uniq
    end

    # Provenance prevents SCIM removals from touching manual enrollment or staff roles.
    def self.reconcile!(membership)
      return unless membership.user
      allowed = membership.active_access? && !membership.user.revoked? ? allowed_cohort_ids(membership) : []
      membership.enterprise_cohort_grants.includes(:cohort_membership).each do |grant|
        enrollment = grant.cohort_membership
        next if allowed.include?(enrollment.cohort_id)
        grant.destroy!
        enrollment.destroy! if enrollment.role == "participant"
      end
      return unless membership.user.participant?
      allowed.each do |cohort_id|
        next if CohortMembership.exists?(user_id: membership.user_id, cohort_id: cohort_id)
        enrollment = CohortMembership.create!(user: membership.user, cohort_id: cohort_id, role: "participant")
        membership.enterprise_cohort_grants.create!(cohort_membership: enrollment)
      end
    end
  end
end
