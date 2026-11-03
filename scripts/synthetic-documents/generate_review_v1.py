#!/usr/bin/env python3
"""Review regressions: fictional inputs only, deterministic PDF/expected pairs."""
import hashlib
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont
from reportlab.lib.utils import ImageReader
from reportlab.pdfgen.canvas import Canvas

ROOT = Path(__file__).resolve().parents[2] / 'api/test/fixtures/files/documents/v2'
OUT = ROOT / 'review-1'
OUT.mkdir(exist_ok=True)


def money(cents):
    return f'{cents / 100:,.2f}'


def row(day, description, cents, kind, merchant=None):
    return dict(posted_on=f'2025-11-{day:02}', description=description,
                signed_amount_cents=cents, event_type=kind, row_kind='posted',
                status='posted', expected_merchant=merchant or description)


def make(name, rows, *, native=True, failed=None, merged=False, supporting=False, scanned=False):
    opening = 100000
    credits = sum(max(r['signed_amount_cents'], 0) for r in rows)
    debits = sum(max(-r['signed_amount_cents'], 0) for r in rows)
    closing = opening + credits - debits
    c = Canvas(str(OUT / name), pagesize=(720, 900), invariant=1)
    groups = [rows[:1], rows[1:]] if scanned else [rows]
    page_count = len(groups) + (2 if supporting else 0)
    if supporting:
        c.setFont('Helvetica-Bold', 18)
        c.drawString(36, 850, 'Statement summary')
        c.setFont('Helvetica', 11)
        c.drawString(36, 800, 'Fictional household: Lina Talun. Your activity follows.')
        c.drawString(36, 760, 'Previous statement issued')
        c.drawString(300, 760, '10/31/2025')
        c.drawString(36, 730, 'Next statement date')
        c.drawString(300, 730, '12/31/2025')
        c.showPage()
    running = opening
    for number, group in enumerate(groups):
        if scanned and number == 1:
            image = Image.new('RGB', (1440, 1300), 'white')
            draw = ImageDraw.Draw(image)
            font = ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial.ttf', 26)
            for i, line in enumerate(['Tasi Demo Checking Account - transaction detail',
                                     'Date      Description                           Debit     Credit    Balance',
                                     '11/06     Tasi Demo groceries                     25.00              1,075.00',
                                     '11/07     Monthly service fee                      5.00              1,070.00',
                                     'Posted totals. Fictional test document.']):
                draw.text((25, 60 + i * 110), line, font=font, fill='black')
            c.drawImage(ImageReader(image), 0, 160, width=720, height=650)
            c.setFont('Helvetica', 9)
            c.drawString(36, 30, 'Fictional scanned activity | Printed on')
            c.drawString(400, 30, '11/30/2025')
            c.showPage()
            continue
        c.setFont('Helvetica-Bold', 18)
        c.drawString(36, 860, 'Tasi Demo Checking Account')
        c.setFont('Helvetica', 10)
        header = [('Account: XXXX1234    Statement period: 11/01/2025 through 11/30/2025') if merged else 'Account: XXXX1234']
        if not merged:
            header.append('Statement period: 11/01/2025 through 11/30/2025')
        header += [f'Beginning balance: ${money(opening)}    Ending balance: ${money(closing)}',
                   f'Posted credits: ${money(credits)}    Posted debits: ${money(debits)}',
                   f'Posted rows: {len(rows)}', 'Fictional statement. Pending excluded from posted totals.']
        for i, line in enumerate(header):
            c.drawString(36, 835-i*15, line)
        c.setFont('Helvetica-Bold', 9)
        for x, label in [(36, 'Date'), (102, 'Description'), (480, 'Debit'), (555, 'Credit'), (635, 'Balance')]:
            c.drawString(x, 715, label)
        for i, event in enumerate(group):
            y = 690 - i * 18
            c.setFont('Helvetica', 8)
            c.drawString(36, y, event['posted_on'][5:].replace('-', '/'))
            c.drawString(102, y, event['description'])
            cents = event['signed_amount_cents']
            c.drawRightString(520 if cents < 0 else 600, y, money(abs(cents)))
            running += cents
            event['running_balance_cents'] = running
            c.drawRightString(690, y, money(running))
        c.drawString(36, 665-len(group)*18, 'Continued on next page' if scanned else 'Posted totals')
        c.showPage()
    if supporting:
        c.setFont('Helvetica-Bold', 18)
        c.drawString(36, 850, 'Important disclosures')
        c.setFont('Helvetica', 11)
        c.drawString(36, 800, 'Fictional bank terms. These are not transactions.')
        c.drawString(36, 760, 'Terms effective')
        c.drawString(300, 760, '11/01/2025')
        c.drawString(36, 720, 'Contact the fictional bank about a statement error.')
        c.showPage()
    c.save()
    expected = dict(filename=name, synthetic=True, kind='statement', format='pdf', page_count=page_count,
                    account_basis='asset', masked_identifier='****1234', period_start_on='2025-11-01',
                    period_end_on='2025-11-30', native=native, failed_pages=failed or [], expected_events=rows,
                    totals_cents=dict(opening_balance_cents=opening, closing_balance_cents=closing,
                                      printed_credit_cents=credits, printed_debit_cents=debits))
    path = OUT / name
    expected.update(sha256=hashlib.sha256(path.read_bytes()).hexdigest(), size_bytes=path.stat().st_size)
    (OUT / f'{name}.expected.json').write_text(json.dumps(expected, indent=2) + '\n')
    return name


docs = [
    make('nsf-return-fee.pdf', [row(5, 'NSF RETURNED UNPAID ITEM FEE', -3500, 'fee')]),
    make('relabelled-summary.pdf', [row(5, 'TOTAL FEES FOR THIS PERIOD', -3500, 'fee')], native=False),
    make('classification-repair.pdf', [row(5, 'Zelle from A', 5000, 'income'),
                                       row(6, 'Mobile check deposit', 7500, 'income'),
                                       row(7, 'Tasi Demo groceries', -2500, 'purchase')], native=False, failed=[1]),
    make('merged-account-period.pdf', [row(5, 'Tasi Demo groceries', -2500, 'purchase')], merged=True),
    make('merchant-locations-numeric-name.pdf', [
        row(5, 'ROSS DRESS FOR LESS #123 DEDEDO GU', -1000, 'purchase', 'Ross'),
        row(6, 'ROSS STORES #456 HAGATNA GU', -2000, 'purchase', 'Ross'),
        row(7, 'KMART #101 HONOLULU HI', -3000, 'purchase', 'Kmart'),
        row(8, 'CARD PURCHASE 1776 COFFEE', -500, 'purchase', '1776 COFFEE'),
        row(9, 'CARD PURCHASE 1776 ROSS COFFEE', -500, 'purchase', '1776 ROSS COFFEE')]),
    make('summary-and-disclosure.pdf', [row(i, f'Tasi Demo shop {i}', -100, 'purchase') for i in range(1, 28)], supporting=True),
    make('scanned-text-footer.pdf', [row(5, 'ACH CREDIT PAYROLL', 10000, 'income'),
                                    row(6, 'Tasi Demo groceries', -2500, 'purchase'),
                                    row(7, 'Monthly service fee', -500, 'fee')], native=False, failed=[2], scanned=True),
]
(OUT / 'manifest.json').write_text(json.dumps(dict(documents=docs), indent=2) + '\n')
print(f'Generated {len(docs)} review regression PDFs and independent expectations')
