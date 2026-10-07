class CreateEnterpriseProvisioning < ActiveRecord::Migration[8.1]
  def change
    create_table :enterprise_organizations do |t|
      t.references :coach_workspace, null: false, foreign_key: true
      t.string :workos_organization_id, null: false
      t.string :name, null: false
      t.boolean :active, null: false, default: true
      t.boolean :require_sso, null: false, default: true
      t.boolean :directory_provisioning_enabled, null: false, default: false
      t.string :directory_id
      t.string :connection_state
      t.string :directory_state
      t.datetime :last_reconciled_at
      t.string :last_sync_error
      t.timestamps
    end
    add_index :enterprise_organizations, :workos_organization_id, unique: true
    add_index :enterprise_organizations, :directory_id, unique: true
    create_table :enterprise_memberships do |t|
      t.references :enterprise_organization, null: false, foreign_key: true
      t.references :user, foreign_key: true
      t.string :workos_user_id, null: false
      t.string :workos_membership_id
      t.string :status, null: false, default: 'pending'
      t.boolean :it_admin, null: false, default: false
      t.boolean :locally_revoked, null: false, default: false
      t.datetime :provider_updated_at
      t.timestamps
    end
    add_index :enterprise_memberships, [ :enterprise_organization_id, :workos_user_id ], unique: true, name: 'enterprise_membership_subject_unique'
    add_index :enterprise_memberships, [ :enterprise_organization_id, :user_id ], unique: true, name: 'enterprise_membership_user_unique'
    add_check_constraint :enterprise_memberships, "status IN ('pending','active','inactive')", name: 'enterprise_membership_status_valid'
    create_table :enterprise_group_mappings do |t|
      t.references :enterprise_organization, null: false, foreign_key: true
      t.references :cohort, null: false, foreign_key: true
      t.string :workos_group_id, null: false
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :enterprise_group_mappings, [ :enterprise_organization_id, :workos_group_id ], unique: true, name: 'enterprise_group_mapping_unique'
    create_table :enterprise_directory_users do |t|
      t.references :enterprise_organization, null: false, foreign_key: true
      t.references :enterprise_membership, foreign_key: true
      t.string :workos_directory_user_id, null: false
      t.string :email
      t.string :state, null: false, default: 'inactive'
      t.datetime :provider_updated_at
      t.timestamps
    end
    add_index :enterprise_directory_users, :workos_directory_user_id, unique: true
    create_table :enterprise_directory_group_memberships do |t|
      t.references :enterprise_directory_user, null: false, foreign_key: true
      t.string :workos_group_id, null: false
      t.boolean :active, null: false, default: false
      t.datetime :provider_updated_at
      t.timestamps
    end
    add_index :enterprise_directory_group_memberships, [ :enterprise_directory_user_id, :workos_group_id ], unique: true, name: 'enterprise_directory_group_edge_unique'
    create_table :enterprise_cohort_grants do |t|
      t.references :enterprise_membership, null: false, foreign_key: true
      t.references :cohort_membership, null: false, foreign_key: { on_delete: :cascade }
      t.timestamps
    end
    add_index :enterprise_cohort_grants, :cohort_membership_id, unique: true, name: 'enterprise_granted_enrollment_unique'
    create_table :enterprise_sync_cursors do |t|
      t.string :name, null: false
      t.string :cursor
      t.datetime :last_polled_at
      t.string :last_error
      t.timestamps
    end
    add_index :enterprise_sync_cursors, :name, unique: true
    create_table :enterprise_sync_events do |t|
      t.string :workos_event_id, null: false
      t.string :event_type, null: false
      t.jsonb :payload, null: false, default: {}
      t.datetime :occurred_at, null: false
      t.datetime :processed_at
      t.integer :attempts, null: false, default: 0
      t.string :last_error
      t.timestamps
    end
    add_index :enterprise_sync_events, :workos_event_id, unique: true
    add_index :enterprise_sync_events, :processed_at
    create_table :enterprise_audit_events do |t|
      t.references :enterprise_organization, null: false, foreign_key: true
      t.references :actor_user, foreign_key: { to_table: :users }
      t.string :action, null: false
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
  end
end
