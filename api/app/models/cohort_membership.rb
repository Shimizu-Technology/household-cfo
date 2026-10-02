class CohortMembership < ApplicationRecord
  ROLES = %w[participant coach admin].freeze

  belongs_to :cohort
  belongs_to :user

  validates :role, inclusion: { in: ROLES }
  validates :user_id, uniqueness: { scope: :cohort_id }

  after_save :reconcile_workspace_access
  after_destroy :reconcile_destroyed_workspace_access

  private

  def reconcile_workspace_access
    affected_access_pairs.each { |workspace, member| self.class.reconcile_workspace_access!(workspace, member) }
  end

  def reconcile_destroyed_workspace_access
    self.class.reconcile_workspace_access!(cohort.coach_workspace, user)
  end

  def affected_access_pairs
    affected_cohorts = [ cohort ]
    affected_users = [ user ]
    if saved_change_to_cohort_id?
      previous_cohort = Cohort.find_by(id: cohort_id_before_last_save)
      affected_cohorts << previous_cohort if previous_cohort
    end
    if saved_change_to_user_id?
      previous_user = User.find_by(id: user_id_before_last_save)
      affected_users << previous_user if previous_user
    end
    affected_cohorts.product(affected_users)
      .map { |affected_cohort, affected_user| [ affected_cohort.coach_workspace, affected_user ] }
      .uniq { |workspace, member| [ workspace.id, member.id ] }
  end

  class << self
    def reconcile_workspace_access!(workspace, user)
      transaction(requires_new: true) do
        connection.exec_query(
          "SELECT pg_advisory_xact_lock($1, $2)",
          "Coach workspace membership reconciliation lock",
          [
            ActiveRecord::Relation::QueryAttribute.new("coach_workspace_id", workspace.id, ActiveRecord::Type::Integer.new),
            ActiveRecord::Relation::QueryAttribute.new("user_id", user.id, ActiveRecord::Type::Integer.new)
          ]
        )
        membership = workspace.coach_workspace_memberships.lock.find_by(user: user)
        qualifying_role = user.coach? && joins(:cohort).where(
          user: user,
          role: %w[coach admin],
          cohorts: { coach_workspace_id: workspace.id }
        ).exists?

        if qualifying_role
          workspace.coach_workspace_memberships.create!(user: user, role: "editor", cohort_managed: true) unless membership
        elsif membership&.cohort_managed?
          membership.destroy!
        end
      end
    end
  end
end
