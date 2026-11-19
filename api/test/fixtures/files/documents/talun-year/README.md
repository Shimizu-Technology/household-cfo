# Talun household: January–December 2026

This is an invented year for **Lina and Mateo Talun**, the fictional household in the original upload corpus. Every name, account, employer, purchase and reference was invented. Institution and subscription names are plain descriptive text; there are no logos, real account numbers or participant records. Every source has a **Synthetic test document** footer.

The set supplies documents and an answer key for the later T4 scorecard. It does not import anything into the app, record model responses or assert that today's app can pass the scorecard. The earlier corpus has different cash-withdrawal expectations; do not combine its totals with this year.

## Scenario

There are **79 documents**, **531 economic events**, **591 account legs**, and **934 source activity rows**. The extra rows comprise **333 true duplicate representations**, **3 receipt matches** and **7 pending authorizations** that later post. Receiving transfer/payment legs are legitimate account movements, not duplicate charges.

| Account | Fictional identifier | Coverage |
| --- | --- | --- |
| Checking, Wells Fargo-style DEMO | `****4410`, debit card `7302` | 12 monthly text PDFs; verbose purchase, recurring-payment, ATM and transfer descriptors |
| Bank of Guam-style DEMO | `****6824` | 6 text PDFs; 3 overlapping phone PNGs each in February, March, May, July, August, September and November |
| Talun savings | `****8642` | 12 monthly text PDFs; matching incoming savings transfers |
| Apple Cash-style DEMO | `****9056` | 12 monthly text PDFs; merchant purchases, debit-card top-ups and transfers to checking |
| Mainland Visa DEMO | `****6074` | 12 monthly text PDFs; purchases, matched checking payments, interest, fees and a refund |

February, May, July, August, September and November have no Bank of Guam PDF. July, August, September and November have **only phone images** for that account, with no CSV either. March intentionally has PDF + screenshots + CSV for the same account entries. In each screenshot month, the day-12 market charge appears pending on day 11 in capture 1 and posted on day 12 in capture 2. Other overlapping posted rows test screenshot deduplication independently of pending-to-posted matching.

`all-accounts-2026-01-to-06.csv` has **298 activity rows across five accounts**, signed amounts and category suggestions. It overlaps all first-half statements and screenshots. Selected CSV dates are 1–3 days earlier than their canonical posting dates, within the same month. It tests account-level money-direction decisions without repeating a question for each line; it is not the separate 1,667-row performance case.

On January 21, Apple Cash has **two separate $6.50 Tasi Demo Coffee purchases** with identical date, amount and descriptor. Both represent distinct fictional purchases, marked by `distinct_purchase_group: january-coffee-twins`; retain two events. Their CSV copies are duplicates of their respective events, not evidence that the two purchases should merge.

Three receipt JPGs match checking debits:

- March 23: clothing subtotal $67.50, coupons $15.00, debit **$52.50**.
- June 23: household goods **$184.88**, voucher/gift card $150.00, new debit **$34.88**. The voucher balance predates this year; there is no new voucher purchase to count.
- October 23: **$103.42**, split into Groceries $73.42, Household $18.00 and Medical $12.00. These allocations replace the bank row's category allocation; they are not additional spending.

Lina has two $2,100 payroll deposits per month. Mateo has two $1,650 payroll deposits and five irregular side-job payments ($185.00, $327.50, $96.00, $442.00, $213.00). Monthly Zelle support goes to the invented parent Neri Talun. Transfers move checking money to savings, Bank of Guam and Apple Cash; Apple Cash also returns $25 each month. Credit-card payments connect checking and Visa.

April power is unpaid until May: May has the current bill, the April arrears and a separate $15 late fee. Streaming rises from $13.99 to $15.99 in July. Medical visits occur in February, June and October. A **$690 appliance repair occurs once**, in September. March's $29.99 clothing refund links to February's card purchase. ATM withdrawals, branch withdrawals and store cash back are all present.

## Accounting conventions

All amounts are integer USD cents. Negative means outflow/charge; positive means inflow/refund/payment credit. Asset balance = opening + credits − debits. Visa liability balance = opening + debits − credits. Balances roll forward continuously, including months represented only by screenshots. Printed PDF totals cover the whole monthly statement and repeat on continued pages; do not add repeated headers together. Screenshots, CSV and receipts do not print account balances or statement totals, so their `printed_totals_cents` is null.

Spending = purchases + fees + interest + cash withdrawals + support to family − refunds. Own-account transfers and card payments are excluded from both spending and income. Transfers are reported once by the originating outflow magnitude, with card payments in a separate field. Refunds reduce spending in their posted month. Only new debit money on the voucher receipt counts.

The fixed category list is in `manifest.categories`. Every spending event has a primary `category` and `category_allocations`; the allocations are authoritative for category totals and sum to the negative signed event amount. Most events have one allocation. The $62.40 monthly store purchase includes $42.40 Groceries and $20 Cash. Monthly Cash spending is therefore **$320**: $100 ATM + $200 branch + $20 store cash back. Fees remain Fees. Income, transfers and card payments have null category and no spending allocations.

Annual answer-key checks: spending **$44,242.95**, income **$91,263.50**, own-account transfers **$9,900.00** (48 events), card payments **$3,000.00** (12 events). There are 333 extra non-pending bank/CSV/screenshot copies of account legs. The three receipt matches are counted separately. Pending authorizations, receiving transfer legs and legitimate identical purchases are excluded from the duplicate count.

## Monthly answer key

All amounts in this section are USD. These values are pinned as literal test constants.

| Month | Spending | Income | Own transfers | Card payments | Bank copies | Receipt matches |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 2026-01 | 3,585.86 | 7,685.00 | 825.00 | 250.00 | 50 | 0 |
| 2026-02 | 3,668.38 | 7,500.00 | 825.00 | 250.00 | 52 | 0 |
| 2026-03 | 3,605.91 | 7,827.50 | 825.00 | 250.00 | 68 | 1 |
| 2026-04 | 3,398.97 | 7,500.00 | 825.00 | 250.00 | 47 | 0 |
| 2026-05 | 3,788.89 | 7,500.00 | 825.00 | 250.00 | 53 | 0 |
| 2026-06 | 3,715.34 | 7,596.00 | 825.00 | 250.00 | 51 | 1 |
| 2026-07 | 3,593.48 | 7,500.00 | 825.00 | 250.00 | 3 | 0 |
| 2026-08 | 3,595.50 | 7,942.00 | 825.00 | 250.00 | 3 | 0 |
| 2026-09 | 4,287.52 | 7,500.00 | 825.00 | 250.00 | 3 | 0 |
| 2026-10 | 3,797.96 | 7,500.00 | 825.00 | 250.00 | 0 | 1 |
| 2026-11 | 3,601.56 | 7,713.00 | 825.00 | 250.00 | 3 | 0 |
| 2026-12 | 3,603.58 | 7,500.00 | 825.00 | 250.00 | 0 | 0 |
| **Annual** | **44,242.95** | **91,263.50** | **9,900.00** | **3,000.00** | **333** | **3** |

Category allocations (USD; refunds reduce the posted month):

| Category | Jan | Feb | Mar | Apr | May | Jun | Jul | Aug | Sep | Oct | Nov | Dec | Annual |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Housing | 1,250.00 | 1,250.00 | 1,250.00 | 1,250.00 | 1,250.00 | 1,250.00 | 1,250.00 | 1,250.00 | 1,250.00 | 1,250.00 | 1,250.00 | 1,250.00 | 15,000.00 |
| Groceries | 588.59 | 590.50 | 592.41 | 594.32 | 596.23 | 598.14 | 600.05 | 601.96 | 603.87 | 679.20 | 607.69 | 609.60 | 7,262.56 |
| Dining | 127.45 | 120.95 | 120.95 | 120.95 | 120.95 | 120.95 | 120.95 | 120.95 | 120.95 | 120.95 | 120.95 | 120.95 | 1,457.90 |
| Transport | 116.61 | 116.72 | 116.83 | 116.94 | 117.05 | 117.16 | 117.27 | 117.38 | 117.49 | 117.60 | 117.71 | 117.82 | 1,406.58 |
| Utilities | 328.23 | 328.23 | 328.23 | 141.78 | 514.68 | 328.23 | 328.23 | 328.23 | 328.23 | 328.23 | 328.23 | 328.23 | 3,938.76 |
| Phone | 65.00 | 65.00 | 65.00 | 65.00 | 65.00 | 65.00 | 65.00 | 65.00 | 65.00 | 65.00 | 65.00 | 65.00 | 780.00 |
| Subscriptions | 13.99 | 13.99 | 13.99 | 13.99 | 13.99 | 13.99 | 15.99 | 15.99 | 15.99 | 15.99 | 15.99 | 15.99 | 179.88 |
| Childcare | 420.00 | 420.00 | 420.00 | 420.00 | 420.00 | 420.00 | 420.00 | 420.00 | 420.00 | 420.00 | 420.00 | 420.00 | 5,040.00 |
| Medical | 0.00 | 87.00 | 0.00 | 0.00 | 0.00 | 91.00 | 0.00 | 0.00 | 0.00 | 107.00 | 0.00 | 0.00 | 285.00 |
| Household | 111.99 | 111.99 | 111.99 | 111.99 | 111.99 | 146.87 | 111.99 | 111.99 | 801.99 | 129.99 | 111.99 | 111.99 | 2,086.76 |
| Clothing | 84.25 | 84.25 | 106.76 | 84.25 | 84.25 | 84.25 | 84.25 | 84.25 | 84.25 | 84.25 | 84.25 | 84.25 | 1,033.51 |
| Cash | 320.00 | 320.00 | 320.00 | 320.00 | 320.00 | 320.00 | 320.00 | 320.00 | 320.00 | 320.00 | 320.00 | 320.00 | 3,840.00 |
| Family support | 125.00 | 125.00 | 125.00 | 125.00 | 125.00 | 125.00 | 125.00 | 125.00 | 125.00 | 125.00 | 125.00 | 125.00 | 1,500.00 |
| Fees | 13.00 | 13.00 | 13.00 | 13.00 | 28.00 | 13.00 | 13.00 | 13.00 | 13.00 | 13.00 | 13.00 | 13.00 | 171.00 |
| Interest | 21.75 | 21.75 | 21.75 | 21.75 | 21.75 | 21.75 | 21.75 | 21.75 | 21.75 | 21.75 | 21.75 | 21.75 | 261.00 |

## Manifest contract: `talun_year_v1`

This is a separate schema from the original corpus's `schema_version: 1`; the original corpus is unchanged. Paths are relative to this directory. IDs are stable fixture joins and are never printed in source documents. They are not permission to infer account ownership or automatically approve matches.

| Field | Meaning |
| --- | --- |
| `raster_renderer` | Platform and Pillow/native font/codec versions used to render images; these can differ between macOS and Linux wheels |
| `accounts[]` | `account_key`, fictional institution/mask, `account_basis`, January opening balance |
| `documents[]` | `path`, `kind`, `format`, `account_keys`, inclusive `period`, `sha256`, `size_bytes`, `synthetic`, `lines`, optional printed totals/receipt detail |
| `documents[].lines[]` | Unique `line_id`, `event_id`, `leg_id`, `account_key`, displayed `date`, `signed_amount_cents`, `description`, `status`, `locator`; CSV also carries `source_category` |
| `events[]` | Stable `event_id`, canonical posted `date`, `signed_amount_cents`, `merchant`, primary `category`, `event_kind`, `category_allocations`, `account_legs`, `representations`; scenario metadata where applicable |
| `events[].account_legs[]` | `leg_id`, `account_key`, signed amount and descriptor. One leg normally; two opposite legs for each own-account transfer or card payment |
| `events[].representations[]` | Every source reference: `document_path`, `line_id`, `leg_id`, `status`, `source_kind` (the document kind); reciprocal to document lines |
| `expected_months[YYYY-MM]` | `spending_by_category_cents`, `total_spending_cents`, `income_cents`, `transfers_cents`, `transfer_count`, `card_payments_cents`, `event_count`, `true_duplicate_count`, `duplicate_groups`, `receipt_match_count`, `receipt_matches` |
| `duplicate_groups[]` | `event_id`, `leg_id`, non-pending bank/CSV/screenshot `line_ids`, `copies` with source references and `source_kind`, and `duplicate_count = copies − 1`; receipts excluded |
| `receipt_matches[]` | Receipt source references with `event_id`, `leg_id`, `document_path`, `line_id`, `status`, `source_kind`; counted by `receipt_match_count` |
| `documents[].receipt` | `matching_bank_event_id`, `new_money_cents`, subtotal, discount, voucher, tax and total cents, item details and expected category allocations |

Event kinds: `purchase`, `income`, `transfer_own_accounts`, `card_payment`, `refund`, `fee`, `interest`, `cash_withdrawal`, `support_to_family`. Extra scenario fields include `refund_of_event_id`, `service_month`, `cadence`, `price_change_on`, `cash_back_cents`, and `distinct_purchase_group`.

A document **line** means a transaction/activity row, or the receipt's debit tender. Receipt items, voucher tender, coupons, headers, summaries and footers support that transaction; they are not additional activity rows. A store purchase with cash back is one bank event with two category allocations, so one bank row still maps to exactly one event. A transfer is one economic event with two account legs, so its opposite account entries are not duplicates.

PDF locators use 1-based page and activity row within the page; CSV locators use the physical 1-based row including the header; PNG locators use 1-based visible row; receipt locators identify the debit tender label. `representations.status: pending` maps to the future posted event for matching only and contributes no additional posted money or duplicate count. Totals and duplicate counts use the event's canonical posted month, not a source's shifted date.

## Regenerate and validate

From the repository root, with Python 3.12, Poppler (`pdftotext`) and the existing pinned requirements:

```sh
uv venv --python 3.12 /tmp/household-cfo-documents
uv pip install --python /tmp/household-cfo-documents/bin/python -r scripts/synthetic-documents/requirements.txt
/tmp/household-cfo-documents/bin/python scripts/synthetic-documents/generate_year.py
/tmp/household-cfo-documents/bin/python -m unittest discover -s scripts/synthetic-documents/tests -v
```

Use `--output /tmp/talun-year` for a scratch generation. The generator writes all source documents and `manifest.json`; this hand-written README is preserved. Generation makes no network, model or database calls, uses no clock or random state, uses ReportLab's bundled Vera fonts with explicit BASIC raster text layout, and fixes PDF metadata with `invariant=1`.

Repeated runs with the same native renderer are byte-identical. Pillow's pinned macOS/Linux wheels can bundle different FreeType, shaping and codec builds, so `raster_renderer` records that environment. Tests compare every output byte across two independent generations on every platform. They also compare all bytes to the committed corpus when the native renderer matches. Across renderer environments, PDF/CSV bytes, raster dimensions/modes and the entire answer key must match; only renderer metadata and raster hashes/sizes may differ. The committed files' own hashes are always verified. Tests pin the monthly/annual answer tables as literal constants, independently recompute totals and duplicates, classify parsed PDF rows and screenshot row sidecars by description, verify complete reciprocal source coverage, parse printed PDF totals/rows with Poppler bounding boxes to verify debit/credit column direction, and compare CSV amounts/categories/dates to their manifest lines.

These fixtures establish the expected numbers, not extraction quality or mobile usability. No app browser journey or live-model extraction is part of T3; T4 must test the review-and-approval journey separately.
