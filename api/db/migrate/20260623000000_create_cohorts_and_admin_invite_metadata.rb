class CreateCohortsAndAdminInviteMetadata < ActiveRecord::Migration[8.1]
  def change
    add_reference :users, :invited_by_user, foreign_key: { to_table: :users }, index: true

    create_table :cohorts do |t|
      t.string :name, null: false
      t.string :status, null: false, default: "draft"
      t.date :starts_on
      t.date :ends_on
      t.text :notes
      t.references :created_by_user, null: false, foreign_key: { to_table: :users }

      t.timestamps
    end

    add_index :cohorts, "lower(name)", unique: true, name: "index_cohorts_on_lower_name"
    add_index :cohorts, :status
    add_check_constraint :cohorts,
      "status IN ('draft', 'enrolling', 'active', 'completed', 'archived')",
      name: "cohorts_status_valid"

    create_table :cohort_memberships do |t|
      t.references :cohort, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :role, null: false, default: "participant"

      t.timestamps
    end

    add_index :cohort_memberships, [ :cohort_id, :user_id ], unique: true
    add_index :cohort_memberships, [ :user_id, :role ]
    add_check_constraint :cohort_memberships,
      "role IN ('participant', 'coach', 'admin')",
      name: "cohort_memberships_role_valid"
  end
end
