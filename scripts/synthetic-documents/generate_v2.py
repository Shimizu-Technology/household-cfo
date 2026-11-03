#!/usr/bin/env python3
"""Fictional noisy statements and photos. Offline; never reads customer files."""
import csv
import hashlib
import json
from pathlib import Path
from PIL import Image, ImageDraw
from reportlab.pdfgen.canvas import Canvas
from reportlab.lib.utils import ImageReader
import generate as v1

ROOT = v1.ROOT / 'api/test/fixtures/files/documents/v2'
ROOT.mkdir(parents=True, exist_ok=True)

def events():
    rows = v1.checking(9)
    rows[0]['description'] = 'ACH CREDIT PAYROLL Government of Guam DEMO'
    rows[12]['description'] = 'POS DEBIT 1234 ROSS STORES #567 XXXX1234'
    rows[17]['description'] = 'POS DEBIT 1234 KMART #101 XXXX1234'
    for row in rows:
        row['expected_merchant'] = {'POS DEBIT 1234 ROSS STORES #567 XXXX1234': 'Ross', 'POS DEBIT 1234 KMART #101 XXXX1234': 'Kmart'}.get(row['description'], row['description'])
    return rows

def pdf(name, rows, *, balance=False, multi=False, cycle=False, card=False, wrapped=False):
    start, end = ('2026-08-15', '2026-09-14') if cycle else ('2026-09-01', '2026-09-30')
    basis = 'liability' if card else 'asset'
    opening = 125000 if card else 245000
    totals = v1.totals(rows, opening, basis)
    groups = [rows[i:i+10] for i in range(0, len(rows), 10)] if multi else [rows]
    c = Canvas(str(ROOT / name), pagesize=(720, 900), invariant=1)
    running = opening
    for page, group in enumerate(groups, 1):
        c.setFont('Helvetica-Bold', 18)
        c.drawString(36, 860, 'Tasi Demo Credit Card Statement' if card else 'Tasi Demo Checking Account')
        c.setFont('Helvetica', 10)
        period = '08/15/2026 - 09/14/2026' if cycle else f'{start} through {end}'
        header = ['Lina Talun — fictional household', 'Account: XXXX1234', f'Statement cycle: {period}',
                  f'Beginning balance: ${v1.money(opening)}    Ending balance: ${v1.money(totals["closing_balance_cents"])}',
                  f'Posted credits: ${v1.money(totals["printed_credit_cents"])}    Posted debits: ${v1.money(totals["printed_debit_cents"])}',
                  f'Posted rows: {sum(r["status"] == "posted" for r in rows)}',
                  'Purchases positive; payments and refunds negative' if card else 'Pending authorizations excluded from posted totals']
        for i, line in enumerate(header): c.drawString(36, 835-i*15, line)
        labels = [(36, 'Date'), (102, 'Description'), (490, 'Amount')] if card else [(36, 'Date'), (102, 'Description'), (480, 'Debit'), (555, 'Credit')]
        if balance: labels.append((635, 'Balance'))
        c.setFont('Helvetica-Bold', 9)
        for x, label in labels: c.drawString(x, 715, label)
        y = 690
        for i, row in enumerate(group):
            c.setFont('Helvetica', 8)
            c.drawString(36, y, row['posted_on'][5:].replace('-', '/'))
            label = row['description'] + (' [PENDING]' if row['status'] == 'pending' else '')
            if wrapped and page == 2 and i == 1:
                c.drawString(102, y, label[:20])
                c.drawString(102, y-10, label[20:])
            else: c.drawString(102, y, label)
            cents = row['signed_amount_cents']
            if card: c.drawRightString(535, y, v1.money(-cents))
            else: c.drawRightString(520 if cents < 0 else 600, y, v1.money(abs(cents)))
            if row['status'] == 'posted': running += cents * (-1 if card else 1)
            if balance: c.drawRightString(690, y, v1.money(running))
            y -= 18
        c.setFont('Helvetica-Bold', 9)
        c.drawString(36, y-10, 'Continued on next page' if page < len(groups) else 'Posted totals')
        c.setFont('Helvetica', 8)
        c.drawString(36, 30, f'Synthetic test document | Fictional account | Page {page} of {len(groups)}')
        c.showPage()
    c.save()
    return dict(filename=name, kind='statement', format='pdf', page_count=len(groups), account_basis=basis, period_start_on=start, period_end_on=end, expected_events=rows, totals_cents=totals)

docs = []
docs.append(pdf('bank-descriptors.pdf', events()))
docs.append(pdf('running-balance.pdf', events(), balance=True))
docs.append(pdf('continued-pages.pdf', events(), multi=True, balance=True))
cycle = events()
for i, row in enumerate(cycle):
    from datetime import date, timedelta
    row['posted_on'] = (date(2026, 8, 15) + timedelta(days=i)).isoformat()
docs.append(pdf('cross-month-cycle.pdf', cycle, cycle=True, balance=True))
card = [v1.event('card-1234', 9, i+1, day, desc, cents, kind) for i, (day, desc, cents, kind) in enumerate([
    (2, 'POS DEBIT 1234 ROSS STORES #567 XXXX1234', -6000, 'purchase'),
    (3, 'KMART #101', -3600, 'purchase'), (5, 'Payment received thank you', 20000, 'debt_payment'),
    (8, 'Ross refund', 1200, 'refund'), (9, 'Interest charge', -425, 'interest'), (10, 'Annual fee', -500, 'fee')])]
for row in card: row['expected_merchant'] = 'Ross' if row['description'].startswith('POS DEBIT') else ('Kmart' if row['description'].startswith('KMART') else row['description'])
docs.append(pdf('credit-card-signed.pdf', card, balance=True, card=True))
docs.append(pdf('wrapped-page.pdf', events(), multi=True, balance=True, wrapped=True))
name = 'metadata-before-header.csv'
with (ROOT / name).open('w', newline='') as f:
    writer = csv.writer(f)
    writer.writerows([['Tasi Demo Bank — fictional export'], ['Account', 'XXXX1234'], ['Exported', '2026-10-01'], [], ['Date', 'Description', 'Debit', 'Credit', 'Status']])
    for row in events():
        cents = row['signed_amount_cents']
        writer.writerow([row['posted_on'], row['description'], v1.money(-cents) if cents < 0 else '', v1.money(cents) if cents > 0 else '', row['status']])
docs.append(dict(filename=name, kind='statement', format='csv', expected_events=events(), totals_cents=v1.totals(events(), 245000), period_start_on='2026-09-01', period_end_on='2026-09-30', account_basis='unknown'))
# Draw a wholly fictional receipt on a creased, tilted paper surface.
receipt = Image.new('RGB', (700, 1000), '#f5f0e5')
d = ImageDraw.Draw(receipt)
for x in range(700):
    shade = 232 + int(16 * abs((x % 220) - 110) / 110)
    d.line((x, 0, x, 999), fill=(shade, shade-3, shade-10))
for i, line in enumerate(['TASI DEMO MARKET', 'Tamuning, Guam', 'FICTIONAL TEST RECEIPT', '09/03/2026 18:42', 'Milk                6.49', 'Bread               4.25', 'Rice               24.99', 'TOTAL USD          35.73', 'VISA XXXX1234', 'Synthetic test document']):
    d.text((60, 90+i*73), line, font=v1.font(27, bold=i in (0,7)), fill='#35312e')
photo = Image.new('RGB', (1000, 1250), '#73685f')
rotated = receipt.rotate(-11, resample=Image.Resampling.BICUBIC, expand=True, fillcolor='#73685f')
photo.paste(rotated, ((1000-rotated.width)//2, (1250-rotated.height)//2))
photo.save(ROOT / 'angled-creased-receipt.jpg', quality=88)
docs.append(dict(filename='angled-creased-receipt.jpg', kind='receipt', format='jpg', expected_events=[], expected_receipt=dict(merchant='Tasi Demo Market', occurred_on='2026-09-03', total_amount_cents=3573, items_cents=[649,425,2499])))
# A wide phone capture, deliberately wider than a portrait viewport.
screen = Image.new('RGB', (1500, 720), '#fcfaf8')
d = ImageDraw.Draw(screen)
for i, line in enumerate(['9:41     Tasi Demo Bank     100%', 'Account XXXX1234 - synthetic test document', 'September 2026 activity', '09/13   POS DEBIT 1234 ROSS STORES #567     -60.00', '09/18   POS DEBIT 1234 KMART #101          -36.00', '09/25   ACH CREDIT PAYROLL              +500.00', '3 posted transactions | Money in 500.00 | Money out 96.00']):
    d.text((45, 30+i*90), line, font=v1.font(31, bold=i in (1,2)), fill='#383044')
screen.save(ROOT / 'wide-phone-capture.png')
wide = [v1.event('screen-1234',9,i+1,day,desc,cents,kind) for i,(day,desc,cents,kind) in enumerate([(13,'POS DEBIT 1234 ROSS STORES #567',-6000,'purchase'),(18,'POS DEBIT 1234 KMART #101',-3600,'purchase'),(25,'ACH CREDIT PAYROLL',50000,'income')])]
docs.append(dict(filename='wide-phone-capture.png', kind='statement', format='png', expected_events=wide, totals_cents=v1.totals(wide), period_start_on='2026-09-01', period_end_on='2026-09-30', account_basis='unknown'))
for doc in docs:
    path = ROOT / doc['filename']
    doc.update(synthetic=True, sha256=hashlib.sha256(path.read_bytes()).hexdigest(), size_bytes=path.stat().st_size)
    (ROOT / (doc['filename'] + '.expected.json')).write_text(json.dumps(doc, indent=2) + '\n')
    if doc['format'] in ('jpg', 'png'):
        response = dict(document_kind=doc['kind'], items=[], transaction_drafts=[], confidence='high', warnings=[], summary='Fictional offline provider contract')
        if doc['kind'] == 'receipt':
            receipt = doc['expected_receipt']
            response['transaction_drafts'] = [dict(occurred_on=receipt['occurred_on'], merchant=receipt['merchant'], total_amount=receipt['total_amount_cents']/100,
                                                  source_type='receipt', evidence='Milk 6.49; Bread 4.25; Rice 24.99; Total 35.73',
                                                  splits=[dict(amount=cents/100, notes='Printed fictional receipt item') for cents in receipt['items_cents']])]
        else:
            response.update(period_start_on=doc['period_start_on'], period_end_on=doc['period_end_on'])
            response['source_accounting'] = dict(contract_version='source_accounting_v1', accounts=[dict(account_key='fixture', account_basis='unknown', period_start_on=doc['period_start_on'], period_end_on=doc['period_end_on'])],
                events=[dict(account_key='fixture', posted_on=row['posted_on'], signed_amount_cents=row['signed_amount_cents'], amount_column_cents=row['signed_amount_cents'],
                             row_kind=row['row_kind'], event_type=row['event_type'], merchant=row['description'], raw_description=row['description'], locator=dict(page=1,row=i+1))
                        for i,row in enumerate(doc['expected_events'])])
        (ROOT / (doc['filename'] + '.response.json')).write_text(json.dumps(response, indent=2) + '\n')
(ROOT / 'manifest.json').write_text(json.dumps(dict(version=2, documents=[d['filename'] for d in docs]), indent=2) + '\n')
print(f'Generated {len(docs)} fictional sources and individual expected-output fixtures in {ROOT}')
