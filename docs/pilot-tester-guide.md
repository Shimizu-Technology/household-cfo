# Household CFO pilot tester guide

This short guide is for the focused four-person Household CFO validation before FinCon. Plaid or a bank connection is not required. The goal is to see whether you can get from a few numbers to one useful Mia conversation without learning every part of the app.

## Your first session

1. Open your email invitation on your phone or computer. Create or sign in to your Clerk account with the invited email. Your display name comes from Clerk; the coach or admin does not enter it for you.
2. On **Home**, choose **Give Mia my starting numbers**.
3. In the focused kickoff, enter your household name, primary goal, monthly income, fixed essentials, and flexible spending. Estimates are okay. A blank money field is treated as $0 when you save.
4. Choose **Save and talk to Mia**. The app takes you directly to **Ask Mia** with this editable starter question: “Based on my income, spending, and goal, what should I focus on first this month?”
5. Send the starter question and confirm Mia answers from the numbers and goal you just saved.
6. Create your first category through Mia. Type: **Create a School Supplies category under Sinking Fund — Expected and plan $75 every month.** You should not need to supply a year; Mia uses the budget year currently open in the workspace.
7. Review the proposed action card. Confirm the category, Expense Stack group, amount, current budget year, and all-12-month scope. Nothing should change before you choose **Apply**.
8. Choose **Apply**, then open **Budget** and confirm School Supplies appears under **Sinking Fund — Expected** with $75 planned in every month.
9. Return to **My Profile** later if you want to add savings, debt, business income, documents, or other details. The advanced fields stay collapsed until you choose **Add details for a stronger CFO read**. Direct Budget editing remains available as a manual fallback, not the required first-session path.

## Budget simplicity and manual fallback

The default **Budget** screen should show the selected month's money in, money out, what remains, the four Expense Stack groups, review work, and a compact annual outlook. The dense annual table, income schedule, and category form should not compete with that overview.

1. Open **Budget**. Confirm **Ask Mia to update my plan** and **Manage manually** are visible near the annual budget heading. The full annual table and income editor should not be visible yet.
2. If the household has a saved debt minimum, confirm the monthly equation explicitly shows **Category plan + Debt minimums = Total money out**. The baseline left and annual cash-flow chart must use that total; debt minimums should not be hidden inside an editable category.
3. Choose **Ask Mia to update my plan**. Confirm the app opens **Ask Mia**, focuses the message box, and prefills: **I want to update my budget. Help me make this change safely:** Add your requested change after the colon; nothing changes until you review and apply Mia's proposal.
4. Return to **Budget** and choose **Manage manually**. The manual manager should appear directly below the annual budget heading—without hunting down the page—and focus **New category**.
5. In **Add a category**, enter **School Supplies — Manual**, choose **Sinking Fund — Expected**, enter **75**, and choose **Add category**. Confirm it appears in the expected stack.
6. Open **Manage manually** again and choose **Edit monthly plan**. Confirm the editable 12-month table appears only now. Change one amount, then confirm the other manual-tool buttons, year/month controls, and close control stay unavailable until you choose the clearly labeled save button or **Cancel**. Choosing the already-active **Edit monthly plan** control must not erase your draft.
7. Open **Manage manually** again and choose **Schedule income**. Confirm the existing income timeline and exact scheduling controls appear in the same focused manager.
8. Close the manual tools. Open **Monthly activity and transactions** only when you need category pressure or the confirmed ledger.

When you switch among Home, Ask Mia, My Profile, Budget, and the other tabs, the destination should begin at the top. On every screen except Home, the Household CFO header should remain compact so the current task is visible without scrolling past the full introduction.

Nothing pending changes your approved household numbers. A transaction or budget change takes effect only after you review and confirm or apply it.

## Optional upload check

Uploads are not required to have a useful first Mia conversation. They are an important pilot check because prior production attempts from Ask Mia and My Profile could not read some spreadsheet/Drive files.

1. Use a demo-safe file with no real account or card numbers. From **Home**, choose **Test a private upload**, or attach it in **Ask Mia**.
2. Upload one supported budget spreadsheet, statement, receipt, screenshot, or pay stub. A Google Drive link is not a file upload; download the file to the device first, then select it in Household CFO.
3. Wait for its review screen. Extracted profile values begin unselected: review, correct, and explicitly check only the values you want before applying them.
4. Read **Review result**. It must name what Mia actually produced—transaction reviews, household setup values, or both—even if that differs from the upload type you selected. The page should explain that nothing changed until you approve it.
5. Add files one at a time while learning the review flow. A statement or receipt can create transaction drafts; review possible matches so a purchase is not counted twice.
6. If a receipt split says **Needs category**, Mia preserved the line instead of guessing. Tap **Review categories**, choose an existing category for every unresolved split, and save. **Confirm** stays unavailable until every split has a category; ignoring the draft still leaves actuals unchanged.
7. Use the explicit **Preview**, **Download**, **Remove source**, and **Delete import** controls. Removing a source file and deleting an import are separate actions.
8. If either upload entry point fails or says it could not read the file, stop and submit **Report a problem** with the file type and workflow—but no document contents or financial values.

Ignoring every extracted transaction does not make that document an approved source. Until at least one value is applied or one transaction is confirmed, My Profile should say **Not approved yet** and **Review pending**, and Mia should continue to say that no approved document source exists.

## Typed and voice Mia

- Open **Ask Mia** and confirm the conversation is the primary, left-hand experience on a computer and the first experience on a phone. The approved-context card remains available after it.
- Choose one example under **Fastest way to update your plan**. It should fill the message box without sending so you can correct the wording first.
- Type a message long enough to wrap across several lines. The message box should grow with the text, keep the attachment, voice, and send controls anchored along its bottom edge, then stop growing and scroll internally after roughly five to six lines. Deleting the text should shrink it back to one line. **Shift + Enter** adds a line break on a computer; **Enter** sends.
- Type a question, transaction, or household change in **Ask Mia**. Mia may prepare a draft, but does not silently change approved numbers.
- For voice, allow microphone access, speak, stop the recording, and review the editable transcript before sending it.
- For a proposed change, review its type, every item, and the monthly **Before → After** impact. Choose **Apply reviewed change** only when it is correct; choose **Cancel draft** to discard it, or **Open manual controls** to use the matching My Profile or Budget interface.
- After Mia prepares a household-number change, manually edit that same value before applying the card. Applying the now-stale card must fail safely and preserve the newer manual value.
- Ask Mia to update a category, set a current household value such as emergency savings or credit-card debt, and schedule a recurring or one-time income change. Each request must stop at a review card before writing.

## If something fails

- A failed upload remains available to retry. Check the file type and size, then try again without re-entering your household setup.
- If Mia or a review step fails, your approved numbers remain unchanged. Retry the step or report the problem.
- Use **Report a problem** at the bottom of the app. Include the screen, what you attempted, what you expected, and what happened.
- A screenshot is optional. Crop it to the smallest useful area before attaching it.

Do not put financial values, account or card numbers, document contents, passwords, or private Mia messages in a feedback report or screenshot. Feedback is stored privately for technical follow-up and is not sent to product analytics.

## Suggested pilot check

Try these on both a computer and your phone when practical:

- Sign in from the invitation and confirm another participant's information is never visible.
- Confirm the invite form required only email, role, and cohort; the participant's Clerk name appears after first sign-in.
- Confirm zero-value money fields are blank while editing, accept the first digit without producing a leading zero, and save a blank as $0.
- Save the five setup essentials and confirm the advanced profile and upload areas stay out of the kickoff.
- Send the prefilled “Based on my income, spending, and goal…” question.
- On a phone, confirm **More prompts →** makes it clear that Mia's suggested questions can be swiped horizontally.
- On a phone, confirm the three update examples swipe horizontally, each target is easy to tap, and selecting one only fills the composer.
- On a phone, type and delete a multi-line message. Confirm the composer grows and shrinks without pushing its icon controls off-screen or introducing horizontal page scrolling.
- Ask Mia to create School Supplies under Sinking Fund — Expected for $75 every month; apply the review card, then verify all 12 months in Budget.
- Ask Mia: **My emergency fund is now $8,500 and my credit card balance is $3,100.** Confirm both proposed values and the cash-flow impact appear on one review card; apply it and verify My Profile and Wealth.
- Ask Mia to change an existing income source beginning a named future month, then test a one-time payment in a different month. Confirm the review card names the source, month, and amount and that Budget's income timeline changes only after approval.
- Ask Mia to set a future recurring income source to **$0** and confirm the review describes an ending—not a deletion of historical income.
- Create a review card, change the same saved value manually, and then apply the old card. Confirm the app rejects it as stale and keeps the newer value.
- Confirm Budget defaults to the simple overview; test the Mia CTA and each focused **Manage manually** task without scrolling to discover its controls.
- Confirm the monthly and annual money-out totals visibly reconcile category plans and debt minimums.
- Create one typed or voice transaction draft and confirm or ignore it.
- From both Ask Mia and My Profile, upload one demo-safe supported file; report the exact entry point and generic file type if either path fails.
- Confirm each completed upload describes the review cards actually produced instead of merely repeating the selected upload type.
- Preview a private source and close it.
- Review one proposed budget change and apply or cancel it.
- Report one demo-safe piece of feedback.

If a result is surprising, leave it pending and report the workflow rather than entering more private detail to explain it.
