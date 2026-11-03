# Fictional statement corpus v2

Generate offline with `scripts/synthetic-documents/generate_v2.py` and the pinned requirements beside it. Every source has a matching `<filename>.expected.json` containing its SHA-256, dates, signed integer cents, row statuses and independently calculated totals. Nothing here comes from a customer.

| Source | Noise / expected outcome |
| --- | --- |
| `bank-descriptors.pdf` | 27 rows; POS DEBIT, ACH CREDIT PAYROLL, store numbers and masked cards; Ross and Kmart aliases |
| `running-balance.pdf` | The same 27 physical rows, with every printed running balance checked |
| `continued-pages.pdf` | 27 rows over three pages; repeated account/table headers and continued footers |
| `cross-month-cycle.pdf` | August 15–September 14; US-style statement-period dates and rows in both months |
| `credit-card-signed.pdf` | Six rows; purchases positive and payments/refunds negative in the printed amount column, translated to economic signed cents |
| `wrapped-page.pdf` | 27 rows over three pages; a numeric-only wrapped continuation on page 2 requires page-only fallback |
| `metadata-before-header.csv` | Four metadata/blank rows before the table; first transaction remains physical row 6 |
| `angled-creased-receipt.jpg` | Fictional tilted receipt with creases; September 3; milk 649¢, bread 425¢, rice 2,499¢; total 3,573¢ |
| `wide-phone-capture.png` | Wide screenshot; three September rows; 50,000¢ in and 9,600¢ out |

The two `.response.json` files are authored offline provider contracts, not claims of OCR accuracy. Tests exercise their normalization and compare dates, rows and totals with the independent expected fixtures. Live verification separately checks the angled receipt and the existing scanned Coast360 fixture. The wrapped-page test verifies that only page 2 is submitted and that its returned amounts cannot override readable source amounts or balances.

Unsupported layouts and ambiguous statements retain the model route. Missing rows, altered printed amounts, wrong signs, out-of-period or reordered dates, and mismatched totals fail closed. A posted-only printed row count is not relabelled to include pending authorizations.
