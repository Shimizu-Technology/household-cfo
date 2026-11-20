class AddMatchedTransactionToSourceReviewVersions < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # A statement line she said is the same purchase as one she already confirmed (a receipt, chat, check-in, form or
  # Plaid purchase) is saved as a match to that purchase: the money moved, and it counts once, as she confirmed it.
  #
  # No foreign key: review versions are immutable (their trigger refuses UPDATE and DELETE), so a nullifying key could
  # never run, and a restricting one would stop a household's purchases from being removed. Readers treat a purchase
  # that is gone or no longer counts as no match, so the line is asked about again.
  def change
    add_column :source_review_versions, :matched_transaction_id, :bigint unless column_exists?(:source_review_versions, :matched_transaction_id)
    add_index :source_review_versions, :matched_transaction_id, where: "matched_transaction_id IS NOT NULL", algorithm: :concurrently, if_not_exists: true
    add_check_constraint :source_review_versions, "matched_transaction_id IS NULL OR (disposition = 'match' AND matched_version_id IS NULL)",
      name: "source_review_matched_transaction", validate: false, if_not_exists: true
    validate_check_constraint :source_review_versions, name: "source_review_matched_transaction"
  end
end
