class IndexSourceReviewOverlapAmounts < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def change
    add_index :financial_source_events, [ :household_id, :signed_amount_cents, :posted_on ], name: "index_source_events_overlap_amount_date", algorithm: :concurrently
    add_index :source_review_versions, [ :household_id, :signed_amount_cents, :posted_on ], name: "index_source_versions_overlap_amount_date", algorithm: :concurrently
  end
end
