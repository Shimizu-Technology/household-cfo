// Exact exceptions, never blanket selectors. New values/rules must pass the policy.
// Remaining component debt belongs to other slices; shared overlays and focus
// rings are intentional. Remove each exception when its owner retires the rule.
export const cssPolicyAllowlist = new Set([
  // Existing component-owned hover; outside W7 stylesheet ownership: .plaid-transaction:hover.
  "[\"src/components/PlaidConnections.css\",\"hover\",[],\".plaid-transaction:hover\",\".plaid-transaction:hover { border-color: color-mix(in srgb, var(--berry) 38%, var(--line)); }\"]",
  // Existing component-owned hover; outside W7 stylesheet ownership: .statement-source-review button:hover:not(:disabled).
  "[\"src/components/StatementSourceReview.css\",\"hover\",[],\".statement-source-review button:hover:not(:disabled)\",\".statement-source-review button:hover:not(:disabled) { border-color: var(--action-primary, #7b4a58); }\"]",
  // Existing component-owned hover; outside W7 stylesheet ownership: .statement-source-review button[type=submit]:hover:not(:disabled), .statement-source-review .source-review-primary:hover:not(:disabled).
  "[\"src/components/StatementSourceReview.css\",\"hover\",[],\".statement-source-review button[type=submit]:hover:not(:disabled), .statement-source-review .source-review-primary:hover:not(:disabled)\",\".statement-source-review button[type=submit]:hover:not(:disabled), .statement-source-review .source-review-primary:hover:not(:disabled) { background: var(--action-primary-hover, #613845); }\"]",
  // Existing component-owned hover; outside W7 stylesheet ownership: .workos-sign-in-dialog > header .workos-sign-in-close:hover.
  "[\"src/components/WorkosSignInDialog.css\",\"hover\",[],\".workos-sign-in-dialog > header .workos-sign-in-close:hover\",\".workos-sign-in-dialog > header .workos-sign-in-close:hover { background: var(--paper-warm); color: var(--ink); }\"]",
  // Existing component-owned hover; outside W7 stylesheet ownership: .cash-flow-month-trigger:hover.
  "[\"src/styles/charts.css\",\"hover\",[],\".cash-flow-month-trigger:hover\",\".cash-flow-month-trigger:hover { outline: none; background: transparent; }\"]",
  // Existing component-owned gradient; outside W7 stylesheet ownership: .pilot-feedback-list > button.active.
  "[\"src/components/PilotFeedbackInbox.css\",\"gradient\",[],\".pilot-feedback-list > button.active\",\"background: linear-gradient(105deg, var(--emerald-soft), rgba(255, 253, 248, 0.86))\"]",
  // Existing component-owned gradient; outside W7 stylesheet ownership: .pilot-feedback-detail.
  "[\"src/components/PilotFeedbackInbox.css\",\"gradient\",[],\".pilot-feedback-detail\",\"background: linear-gradient(180deg, rgba(255, 253, 248, 0.95), rgba(251, 247, 243, 0.84))\"]",
  // Intentional floating surface or focus ring: .participant-private-access > p.
  "[\"src/App.css\",\"shadow\",[],\".participant-private-access > p\",\"box-shadow: var(--shadow-sm)\"]",
  // Intentional floating surface or focus ring: .tabs-secondary.
  "[\"src/App.css\",\"shadow\",[],\".tabs-secondary\",\"box-shadow: var(--shadow-overlay)\"]",
  // Intentional floating surface or focus ring: .pilot-dialog.
  "[\"src/App.css\",\"shadow\",[],\".pilot-dialog\",\"box-shadow: var(--shadow-overlay)\"]",
  // Intentional floating surface or focus ring: .tabs-secondary.
  "[\"src/App.css\",\"shadow\",[\"@media (max-width: 620px)\"],\".tabs-secondary\",\"box-shadow: var(--shadow-overlay)\"]",
  // Intentional floating surface or focus ring: .document-preview-modal.
  "[\"src/App.css\",\"shadow\",[],\".document-preview-modal\",\"box-shadow: var(--shadow-overlay)\"]",
  // Intentional floating surface or focus ring: .mia-chat-shell.is-expanded.
  "[\"src/App.css\",\"shadow\",[],\".mia-chat-shell.is-expanded\",\"box-shadow: var(--shadow-overlay)\"]",
  // Intentional floating surface or focus ring: .clear-chat-dialog.
  "[\"src/App.css\",\"shadow\",[],\".clear-chat-dialog\",\"box-shadow: var(--shadow-overlay)\"]",
  // Intentional floating surface or focus ring: .mia-suggestions-panel.
  "[\"src/App.css\",\"shadow\",[],\".mia-suggestions-panel\",\"box-shadow: var(--shadow-md)\"]",
  // Intentional floating surface or focus ring: .chat-scroll-bottom-button.
  "[\"src/App.css\",\"shadow\",[],\".chat-scroll-bottom-button\",\"box-shadow: var(--shadow-md)\"]",
  // Intentional floating surface or focus ring: .chat-scroll-bottom-button:hover.
  "[\"src/App.css\",\"shadow\",[\"@media (hover: hover) and (pointer: fine)\"],\".chat-scroll-bottom-button:hover\",\"box-shadow: var(--shadow-md)\"]",
  // Intentional floating surface or focus ring: .local-attachment-preview.
  "[\"src/App.css\",\"shadow\",[],\".local-attachment-preview\",\"box-shadow: var(--shadow-overlay)\"]",
  // Intentional floating surface or focus ring: .mia-suggestions-panel.
  "[\"src/App.css\",\"shadow\",[\"@media (max-width: 620px)\"],\".mia-suggestions-panel\",\"box-shadow: var(--shadow-overlay)\"]",
  // Intentional floating surface or focus ring: .first-session-setup-options.
  "[\"src/App.css\",\"shadow\",[],\".first-session-setup-options\",\"box-shadow: var(--shadow-md)\"]",
  // Intentional floating surface or focus ring: .mia-context-drawer.
  "[\"src/App.css\",\"shadow\",[],\".mia-context-drawer\",\"box-shadow: var(--shadow-md)\"]",
  // Intentional floating surface or focus ring: .shell-account-panel.
  "[\"src/App.css\",\"shadow\",[],\".shell-account-panel\",\"box-shadow: var(--shadow-md)\"]",
  // Intentional floating surface or focus ring: .participant-program-switch > .participant-program-picker.
  "[\"src/App.css\",\"shadow\",[],\".participant-program-switch > .participant-program-picker\",\"box-shadow: var(--shadow-md)\"]",
  // Existing component-owned shadow; outside W7 stylesheet ownership: .bank-resume-dialog.
  "[\"src/components/BankActivityResumeDialog.css\",\"shadow\",[],\".bank-resume-dialog\",\"box-shadow: var(--shadow-overlay)\"]",
  // Existing component-owned shadow; outside W7 stylesheet ownership: .baseline-dialog.
  "[\"src/components/BaselineReview.css\",\"shadow\",[],\".baseline-dialog\",\"box-shadow: var(--shadow-overlay)\"]",
  // Existing component-owned shadow; outside W7 stylesheet ownership: .challenge-privacy-dialog.
  "[\"src/components/ChallengePrivacyDialog.css\",\"shadow\",[],\".challenge-privacy-dialog\",\"box-shadow: var(--shadow-overlay)\"]",
  // Existing component-owned shadow; outside W7 stylesheet ownership: .daily-dialog.
  "[\"src/components/ChallengeToday.css\",\"shadow\",[],\".daily-dialog\",\"box-shadow: var(--shadow-overlay)\"]",
  // Existing component-owned shadow; outside W7 stylesheet ownership: .coach-source-guard.
  "[\"src/components/CoachContentSources.css\",\"shadow\",[],\".coach-source-guard\",\"box-shadow: var(--shadow-soft)\"]",
  // Intentional floating surface or focus ring: .cohort-release-modal.
  "[\"src/components/CoachStudio.css\",\"shadow\",[],\".cohort-release-modal\",\"box-shadow: 0 1.5rem 4rem rgb(32 25 28 / 30%)\"]",
  // Existing component-owned shadow; outside W7 stylesheet ownership: .mia-assist-panel.is-modal.
  "[\"src/components/MiaAssistPanels.css\",\"shadow\",[],\".mia-assist-panel.is-modal\",\"box-shadow: var(--shadow-overlay)\"]",
  // Existing component-owned shadow; outside W7 stylesheet ownership: .optional-debt-dialog.
  "[\"src/components/OptionalDebtReview.css\",\"shadow\",[],\".optional-debt-dialog\",\"box-shadow: var(--shadow-overlay)\"]",
  // Existing component-owned shadow; outside W7 stylesheet ownership: .pilot-feedback-filters button[aria-pressed="true"].
  "[\"src/components/PilotFeedbackInbox.css\",\"shadow\",[],\".pilot-feedback-filters button[aria-pressed=\\\"true\\\"]\",\"box-shadow: inset 0 0 0 1px rgba(23, 96, 87, 0.06)\"]",
  // Existing component-owned shadow; outside W7 stylesheet ownership: .pilot-feedback-list > button.active.
  "[\"src/components/PilotFeedbackInbox.css\",\"shadow\",[],\".pilot-feedback-list > button.active\",\"box-shadow: inset 4px 0 0 var(--emerald)\"]",
  // Existing component-owned shadow; outside W7 stylesheet ownership: .plaid-health-mark.
  "[\"src/components/PlaidConnections.css\",\"shadow\",[],\".plaid-health-mark\",\"box-shadow: var(--shadow-sm)\"]",
  // Existing component-owned shadow; outside W7 stylesheet ownership: .plaid-state-mark.
  "[\"src/components/PlaidConnections.css\",\"shadow\",[],\".plaid-state-mark\",\"box-shadow: 0 0 0 4px color-mix(in srgb, var(--paper-deep) 45%, transparent)\"]",
  // Existing component-owned shadow; outside W7 stylesheet ownership: .plaid-transaction.is-needs_review .plaid-state-mark.
  "[\"src/components/PlaidConnections.css\",\"shadow\",[],\".plaid-transaction.is-needs_review .plaid-state-mark\",\"box-shadow: var(--shadow-sm)\"]",
  // Existing component-owned shadow; outside W7 stylesheet ownership: .plaid-transaction.is-confirmed .plaid-state-mark.
  "[\"src/components/PlaidConnections.css\",\"shadow\",[],\".plaid-transaction.is-confirmed .plaid-state-mark\",\"box-shadow: var(--shadow-sm)\"]",
  // Existing component-owned shadow; outside W7 stylesheet ownership: .plaid-transaction.is-source_changed .plaid-state-mark.
  "[\"src/components/PlaidConnections.css\",\"shadow\",[],\".plaid-transaction.is-source_changed .plaid-state-mark\",\"box-shadow: var(--shadow-sm)\"]",
  // Existing component-owned shadow; outside W7 stylesheet ownership: .plaid-activity-tabs button.is-active.
  "[\"src/components/PlaidConnections.css\",\"shadow\",[],\".plaid-activity-tabs button.is-active\",\"box-shadow: var(--shadow-sm)\"]",
  // Existing component-owned shadow; outside W7 stylesheet ownership: .evidence-dialog.
  "[\"src/components/SavingsEvidenceDialog.css\",\"shadow\",[],\".evidence-dialog\",\"box-shadow: var(--shadow-overlay)\"]",
  // Existing component-owned shadow; outside W7 stylesheet ownership: .workos-sign-in-dialog.
  "[\"src/components/WorkosSignInDialog.css\",\"shadow\",[],\".workos-sign-in-dialog\",\"box-shadow: var(--shadow-overlay)\"]",
  // Existing component-owned shadow; outside W7 stylesheet ownership: .workspace-opening-panel.
  "[\"src/components/WorkspaceOpening.css\",\"shadow\",[],\".workspace-opening-panel\",\"box-shadow: var(--shadow-md)\"]",
  // Intentional floating surface or focus ring: .chat-more-menu.
  "[\"src/styles/mia.css\",\"shadow\",[],\".chat-more-menu\",\"box-shadow: var(--shadow-md)\"]",
  // Intentional floating surface or focus ring: .brand-bootstrap-mark, .shell-mia-mark, .tabs :where(button, a).active.
  "[\"src/App.css\",\"side-border\",[\"@media (forced-colors: active)\"],\".brand-bootstrap-mark, .shell-mia-mark, .tabs :where(button, a).active\",\"border: 2px solid ButtonText\"]",
  // Intentional floating surface or focus ring: .document-processing-state span.
  "[\"src/App.css\",\"side-border\",[],\".document-processing-state span\",\"border: 2px solid rgba(123, 74, 88, 0.18)\"]",
  // Intentional floating surface or focus ring: .document-preview-spinner.
  "[\"src/App.css\",\"side-border\",[],\".document-preview-spinner\",\"border: 2px solid rgba(123, 74, 88, 0.18)\"]",
  // Existing component-owned side-border; outside W7 stylesheet ownership: .coach-source-snapshot-note.
  "[\"src/components/CoachContentSources.css\",\"side-border\",[],\".coach-source-snapshot-note\",\"border-left: 0.2rem solid var(--mauve)\"]",
  // Existing component-owned side-border; outside W7 stylesheet ownership: .coach-source-safety.
  "[\"src/components/CoachContentSources.css\",\"side-border\",[],\".coach-source-safety\",\"border-left: 0.25rem solid var(--status-red)\"]",
  // Existing component-owned side-border; outside W7 stylesheet ownership: .pilot-feedback-narrative > div.
  "[\"src/components/PilotFeedbackInbox.css\",\"side-border\",[],\".pilot-feedback-narrative > div\",\"border-left: 3px solid rgba(123, 74, 88, 0.2)\"]",
  // Existing component-owned side-border; outside W7 stylesheet ownership: .savings-home .savings-secondary, .savings-home .savings-action.
  "[\"src/components/SavingsChallengeHome.css\",\"side-border\",[],\".savings-home .savings-secondary, .savings-home .savings-action\",\"border: 1.5px solid var(--emerald)\"]",
  // Existing component-owned side-border; outside W7 stylesheet ownership: .evidence-legs.
  "[\"src/components/SavingsEvidenceDialog.css\",\"side-border\",[],\".evidence-legs\",\"border-left: 2px solid var(--line,#cad6d2)\"]",
  // Existing component-owned side-border; outside W7 stylesheet ownership: .source-event-unresolved.
  "[\"src/components/StatementSourceReview.css\",\"side-border\",[],\".source-event-unresolved\",\"border-left-width: 4px\"]",
  // Existing component-owned side-border; outside W7 stylesheet ownership: .opening-progress-indicator.
  "[\"src/components/WorkspaceOpening.css\",\"side-border\",[],\".opening-progress-indicator\",\"border: 2px solid currentColor\"]",
  // Existing component-owned side-border; outside W7 stylesheet ownership: .expense-stack-row.stack-sinking_unexpected .expense-stack-row-heading strong::before.
  "[\"src/styles/charts.css\",\"side-border\",[],\".expense-stack-row.stack-sinking_unexpected .expense-stack-row-heading strong::before\",\"border: 2px solid var(--group-color)\"]",
  // Existing component-owned glass; outside W7 stylesheet ownership: .workos-sign-in-backdrop.
  "[\"src/components/WorkosSignInDialog.css\",\"glass\",[],\".workos-sign-in-backdrop\",\"backdrop-filter: blur(7px)\"]",
])
