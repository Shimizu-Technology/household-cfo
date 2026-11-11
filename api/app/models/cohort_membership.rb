class CohortMembership < ApplicationRecord
  PREVIEW_ROLE = "preview".freeze
  # A preview seat that was left keeps its row, because a challenge enrollment
  # accepted through it still points at it. It is never a seat again.
  ENDED_PREVIEW_ROLE = "preview_ended".freeze
  PREVIEW_ROLES = [ PREVIEW_ROLE, ENDED_PREVIEW_ROLE ].freeze
  ROLES = (%w[participant coach admin] + PREVIEW_ROLES).freeze

  # A preview seat is not a member of the program. It fails closed: every query
  # that goes through this model, `user.cohort_memberships` or
  # `cohort.cohort_memberships` leaves previews out, so a roster, count, report
  # or export that forgets about them still excludes them. Code that must see a
  # preview asks for it by name with `seats`, `previews` or `with_previews`.
  default_scope { where.not(role: PREVIEW_ROLES) }
  scope :with_previews, -> { unscope(where: :role) }
  scope :previews, -> { with_previews.where(role: PREVIEW_ROLE) }
  scope :all_previews, -> { with_previews.where(role: PREVIEW_ROLES) }
  # A preview seat is honoured only while its holder may still preview that group:
  # still an unrevoked coach or admin, the group not archived, and (for a coach)
  # still on the group's coach workspace. Every reader of a seat goes through
  # `seats` or `live_previews`, so a seat that outlives that right is simply not
  # there, whatever else still holds the row.
  LIVE_PREVIEW_SQL = <<~SQL.squish.freeze
    cohort_memberships.role = 'preview' AND EXISTS (
      SELECT 1 FROM cohorts seat_cohort INNER JOIN users seat_user ON seat_user.id = cohort_memberships.user_id
      WHERE seat_cohort.id = cohort_memberships.cohort_id AND seat_cohort.status <> 'archived'
        AND seat_user.role IN ('coach', 'admin') AND seat_user.invitation_status <> 'revoked'
        AND (seat_user.role = 'admin' OR EXISTS (
          SELECT 1 FROM coach_workspace_memberships seat_workspace
          WHERE seat_workspace.user_id = seat_user.id AND seat_workspace.coach_workspace_id = seat_cohort.coach_workspace_id)))
  SQL
  scope :live_previews, -> { with_previews.where(LIVE_PREVIEW_SQL) }
  scope :seats, -> { with_previews.where("cohort_memberships.role = 'participant' OR (#{LIVE_PREVIEW_SQL})") }

  belongs_to :cohort
  belongs_to :user

  validates :role, inclusion: { in: ROLES }
  validates :user_id, uniqueness: { scope: %i[cohort_id role] }
  validate :preview_is_for_staff

  after_save :reconcile_workspace_access, unless: :preview?
  after_destroy :reconcile_destroyed_workspace_access, unless: :preview?

  def preview?
    role == PREVIEW_ROLE
  end

  # Ends a preview seat: gone if nothing refers to it, kept as history if an enrollment does.
  def end_preview!
    raise ArgumentError, "Only a preview seat can end" unless preview?

    SavingsEnrollment.exists?(accepted_cohort_membership_id: id) ? update!(role: ENDED_PREVIEW_ROLE) : destroy!
  end

  # The membership role a person sits in the app with.
  def self.seat_role_for(user)
    user&.staff? ? PREVIEW_ROLE : "participant"
  end

  private

  def preview_is_for_staff
    errors.add(:role, "preview seats are only for coaches and admins") if preview? && !user&.staff?
  end

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
      .sort_by { |workspace, member| [ workspace.id, member.id ] }
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
