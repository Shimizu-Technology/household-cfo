#!/usr/bin/env python3
"""Generate the fictional Talun 2026 ledger and documents, entirely offline."""
import argparse
import calendar
from collections import defaultdict
import csv
from datetime import date, timedelta
import hashlib
import json
from pathlib import Path
import platform
import textwrap

from PIL import Image, ImageDraw, ImageFont, __version__ as pillow_version, features
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.pdfgen.canvas import Canvas

import generate as v1

DEFAULT_OUTPUT = v1.DEFAULT_OUTPUT / 'talun-year'
CATEGORIES = ['Housing', 'Groceries', 'Dining', 'Transport', 'Utilities', 'Phone',
              'Subscriptions', 'Childcare', 'Medical', 'Household', 'Clothing',
              'Cash', 'Family support', 'Fees', 'Interest']
SPENDING_KINDS = {'purchase', 'fee', 'interest', 'cash_withdrawal', 'support_to_family', 'refund'}
ACCOUNTS = [
    dict(account_key='checking', institution='Wells Fargo-style DEMO', masked_identifier='****4410',
         account_basis='asset', opening_balance_cents=275000),
    dict(account_key='bog', institution='Bank of Guam-style DEMO', masked_identifier='****6824',
         account_basis='asset', opening_balance_cents=180000),
    dict(account_key='savings', institution='Talun Savings DEMO', masked_identifier='****8642',
         account_basis='asset', opening_balance_cents=500000),
    dict(account_key='apple', institution='Apple Cash-style DEMO', masked_identifier='****9056',
         account_basis='asset', opening_balance_cents=25000),
    dict(account_key='card', institution='Mainland Visa DEMO', masked_identifier='****6074',
         account_basis='liability', opening_balance_cents=340000),
]
SCREEN_MONTHS = {2, 5, 7, 8, 9, 11}


def period(month):
    return dict(start_on=f'2026-{month:02}-01',
                end_on=f'2026-{month:02}-{calendar.monthrange(2026, month)[1]}')


def amount(cents):
    """Format cents without floating point or locale dependence."""
    return f'{"-" if cents < 0 else ""}{abs(cents) // 100:,}.{abs(cents) % 100:02}'


def ledger():
    events = []

    def add(month, slug, day, account, merchant, cents, category=None, kind='purchase',
            description=None, other=None, allocations=None, **extra):
        event_id = f'talun-2026-{month:02}-{slug}'
        movement = dict(account_key=account, signed_amount_cents=cents,
                        description=description or merchant)
        legs = [movement]
        if other:
            target, label = other
            legs.append(dict(account_key=target, signed_amount_cents=-cents, description=label))
        for leg in legs:
            leg['leg_id'] = f'{event_id}:{leg["account_key"]}'
        event = dict(event_id=event_id, date=f'2026-{month:02}-{day:02}',
                     signed_amount_cents=cents, merchant=merchant, category=category,
                     event_kind=kind, category_allocations=allocations or (
                         [dict(category=category, spending_cents=-cents)] if kind in SPENDING_KINDS else []),
                     account_legs=legs, representations=[], **extra)
        events.append(event)
        return event

    for m in range(1, 13):
        def purchase(slug, day, merchant, cents, category, **extra):
            return add(m, slug, day, 'checking', merchant, -cents, category,
                       description=f'Purchase authorized on {m:02}/{day:02} {merchant} Tamuning Gum S*····7788 Card 7302', **extra)

        add(m, 'lina-pay-1', 1, 'checking', 'Lina DEMO government payroll', 210000, kind='income')
        add(m, 'lina-pay-2', 15, 'checking', 'Lina DEMO government payroll', 210000, kind='income')
        add(m, 'rent', 2, 'checking', 'Talun family home rent', -125000, 'Housing', cadence='monthly')
        purchase('childcare', 3, 'Tasi Demo Childcare', 42000, 'Childcare', cadence='monthly')
        purchase('groceries-1', 4, 'Tasi Demo Market', 10342 + m * 37, 'Groceries')
        purchase('groceries-2', 18, 'Tasi Demo Market', 14782 + m * 21, 'Groceries')
        purchase('fuel', 5, 'Tasi Demo Fuel', 4875 + m * 11, 'Transport')
        # April power is unpaid until May. The arrears and late fee are separate posted lines.
        if m != 4:
            add(m, 'power', 6, 'checking', 'Tasi Demo Power', -18645, 'Utilities',
                description='Tasi Demo Power current monthly bill', service_month=f'2026-{m:02}')
        if m == 5:
            add(m, 'power-arrears', 7, 'checking', 'Tasi Demo Power past due', -18645, 'Utilities',
                description='Tasi Demo Power past-due April bill paid late', service_month='2026-04')
            add(m, 'power-late-fee', 7, 'checking', 'Tasi Demo Power late fee', -1500, 'Fees', kind='fee')
        add(m, 'water', 7, 'checking', 'Tasi Demo Water', -5678, 'Utilities')
        add(m, 'streaming', 8, 'checking', 'Google Youtubeprem', -(1399 if m <= 6 else 1599), 'Subscriptions',
            description=f'Recurring Payment authorized on {m:02}/08 Google Youtubeprem 650-····1111 CA S*····8899 Card 7302',
            cadence='monthly', price_change_on='2026-07-08')
        add(m, 'phone', 9, 'checking', 'Tasi Demo Mobile', -6500, 'Phone', cadence='monthly',
            description=f'Recurring Payment authorized on {m:02}/09 Tasi Demo Mobile Card 7302')
        add(m, 'savings-transfer', 10, 'checking', 'Talun own savings', -20000, kind='transfer_own_accounts',
            description='Online Transfer to Talun Savings DEMO ****8642',
            other=('savings', 'Online Transfer from own checking DEMO ****4410'))
        add(m, 'bank-transfer', 11, 'checking', 'Talun own Bank of Guam', -50000, kind='transfer_own_accounts',
            description='Online Transfer to own Bank of Guam DEMO ****6824',
            other=('bog', 'Transfer from own checking DEMO ****4410'))
        add(m, 'apple-topup', 12, 'checking', 'Apple Cash card top-up', -10000, kind='transfer_own_accounts',
            description='APPLE CASH SENT MONEY card top-up ****9056',
            other=('apple', 'Card top-up from own debit card 7302'))
        add(m, 'card-payment', 13, 'checking', 'Mainland Visa payment', -25000, kind='card_payment',
            description='Online Payment to Mainland Visa DEMO ****6074',
            other=('card', 'Payment received from Talun checking ****4410'))
        purchase('dinner', 14, 'Tasi Demo Dining Room', 6720, 'Dining')
        add(m, 'family-support', 16, 'checking', 'Neri Talun (fictional parent)', -12500, 'Family support',
            kind='support_to_family', description='Zelle to Neri Talun DEMO parent support')
        add(m, 'atm', 17, 'checking', 'Non-WF ATM Tamuning DEMO', -10000, 'Cash', kind='cash_withdrawal',
            description=f'Non-WF ATM Withdrawal authorized on {m:02}/17 Tamuning Gum Card 7302')
        add(m, 'atm-fee', 17, 'checking', 'ATM Transaction Fee', -300, 'Fees', kind='fee')
        add(m, 'cashback', 20, 'checking', 'Tasi Demo Market', -6240, 'Groceries',
            description=f'Purchase authorized on {m:02}/20 Tasi Demo Market 42.40 + Cash back 20.00 Card 7302',
            allocations=[dict(category='Groceries', spending_cents=4240), dict(category='Cash', spending_cents=2000)],
            cash_back_cents=2000)
        if m in {2, 6, 10}:
            purchase('medical', 21, 'Tasi Demo Clinic', 8500 + m * 100, 'Medical', cadence='one_time')
        if m == 9:
            purchase('one-off-repair', 22, 'Tasi Demo Appliance Repair', 69000, 'Household', cadence='one_time')
        if m == 3:
            purchase('coupon-receipt', 23, 'Tasi Demo Outfitters', 5250, 'Clothing', receipt_key='coupons')
        if m == 6:
            purchase('voucher-receipt', 23, 'Tasi Demo Home Store', 3488, 'Household', receipt_key='voucher')
        if m == 10:
            purchase('mixed-receipt', 23, 'Tasi Demo Market', 10342, 'Groceries', receipt_key='mixed',
                     allocations=[dict(category='Groceries', spending_cents=7342),
                                  dict(category='Household', spending_cents=1800),
                                  dict(category='Medical', spending_cents=1200)])

        add(m, 'mateo-pay-1', 2, 'bog', 'Tasi Services DEMO payroll Mateo', 165000, kind='income')
        add(m, 'mateo-pay-2', 16, 'bog', 'Tasi Services DEMO payroll Mateo', 165000, kind='income')
        for n, day in enumerate([4, 8, 12, 19, 24], 1):
            add(m, f'bog-market-{n}', day, 'bog', 'Tasi Demo Market', -(2800 + m * 23 + n * 77), 'Groceries',
                description='POS PURCHASE TASI DEMO MARKET MANGILAO GU', pending_screenshot=n == 3)
        add(m, 'branch-cash', 10, 'bog', 'Bank of Guam DEMO branch', -20000, 'Cash', kind='cash_withdrawal',
            description='BRANCH CASH WITHDRAWAL - HAGATNA DEMO')
        add(m, 'bog-fuel', 14, 'bog', 'Tasi Demo Fuel', -5200, 'Transport')
        add(m, 'bog-internet', 18, 'bog', 'Tasi Demo Internet', -8500, 'Utilities', cadence='monthly')
        add(m, 'bog-dining', 22, 'bog', 'Tasi Demo Noodle House', -2850, 'Dining')
        add(m, 'bog-fee', 27, 'bog', 'Monthly service fee', -500, 'Fees', kind='fee')
        if m in {1, 3, 6, 8, 11}:
            side = {1: 18500, 3: 32750, 6: 9600, 8: 44200, 11: 21300}[m]
            add(m, 'side-job', 25, 'bog', 'Mateo DEMO weekend repairs', side, kind='income', cadence='irregular')

        for slug, day, merchant, cents, category in [
            ('apple-lunch', 13, 'Tasi Demo Dining Room', 1875, 'Dining'),
            ('apple-market', 17, 'Tasi Demo Market', 2250 + m * 5, 'Groceries'),
            ('apple-coffee', 21, 'Tasi Demo Coffee', 650, 'Dining'),
            ('apple-bus', 24, 'Tasi Demo Bus', 1575, 'Transport'),
        ]:
            add(m, slug, day, 'apple', merchant, -cents, category,
                description=f'Apple Cash purchase - {merchant} GU',
                **({'distinct_purchase_group': 'january-coffee-twins'} if m == 1 and slug == 'apple-coffee' else {}))
        if m == 1:
            add(m, 'apple-coffee-twin', 21, 'apple', 'Tasi Demo Coffee', -650, 'Dining',
                description='Apple Cash purchase - Tasi Demo Coffee GU',
                distinct_purchase_group='january-coffee-twins')
        add(m, 'apple-to-bank', 26, 'apple', 'Apple Cash transfer to bank', -2500, kind='transfer_own_accounts',
            description='Transfer to own bank ****4410', other=('checking', 'APPLE CASH TRANSFER FROM OWN WALLET ****9056'))
        for slug, day, merchant, cents, category in [
            ('card-market', 4, 'Tasi Demo Market', 11899 + m * 13, 'Groceries'),
            ('card-clothing', 9, 'Tasi Demo Outfitters', 8425, 'Clothing'),
            ('card-household', 19, 'Tasi Demo Home Store', 7400, 'Household'),
            ('card-online', 22, 'Tasi Demo Online Shop', 3799, 'Household'),
        ]:
            add(m, slug, day, 'card', merchant, -cents, category)
        if m == 3:
            add(m, 'linked-refund', 6, 'card', 'Tasi Demo Outfitters', 2999, 'Clothing', kind='refund',
                description='Merchandise refund from February clothing purchase',
                refund_of_event_id='talun-2026-02-card-clothing')
        add(m, 'card-interest', 27, 'card', 'Purchase interest charge', -2175, 'Interest', kind='interest')
        add(m, 'card-fee', 27, 'card', 'Card service fee', -500, 'Fees', kind='fee')
    return sorted(events, key=lambda e: (e['date'], e['event_id']))


def account_rows(events, account, month):
    return [dict(event_id=e['event_id'], leg_id=leg['leg_id'], account_key=account,
                 date=e['date'], signed_amount_cents=leg['signed_amount_cents'],
                 description=leg['description'], status='posted')
            for e in events if e['date'][5:7] == f'{month:02}'
            for leg in e['account_legs'] if leg['account_key'] == account]


def reconciliation(rows, opening, basis):
    posted = [r['signed_amount_cents'] for r in rows if r['status'] == 'posted']
    credit = sum(max(c, 0) for c in posted)
    debit = sum(max(-c, 0) for c in posted)
    return dict(opening_balance_cents=opening, printed_credit_cents=credit,
                printed_debit_cents=debit,
                closing_balance_cents=opening + (credit - debit) * (-1 if basis == 'liability' else 1))


def fonts():
    # Bundled Vera has middle-dot glyphs; never depend on macOS/system fonts.
    for name, filename in [('Talun', 'Vera.ttf'), ('TalunBold', 'VeraBd.ttf')]:
        if name not in pdfmetrics.getRegisteredFontNames():
            pdfmetrics.registerFont(TTFont(name, str(v1.FONT_DIR / filename)))


def raster_font(size, bold=False):
    return ImageFont.truetype(str(v1.FONT_DIR / ('VeraBd.ttf' if bold else 'Vera.ttf')),
                             size, layout_engine=ImageFont.Layout.BASIC)


def statement(path, account, rows, month, totals):
    fonts()
    c = Canvas(str(path), pagesize=(792, 900), invariant=1, pageCompression=1)
    c.setTitle(f'Talun fictional {account["account_key"]} 2026-{month:02}')
    c.setAuthor('Household CFO synthetic corpus generator')
    chunks = [rows[i:i + 18] for i in range(0, len(rows), 18)]
    for page, chunk in enumerate(chunks, 1):
        c.setFont('TalunBold', 18)
        c.drawString(32, 862, account['institution'])
        c.setFont('Talun', 10)
        p = period(month)
        header = [v1.PERSON, f'Account: {account["masked_identifier"]} | Fictional test account',
                  f'Statement period: {p["start_on"]} through {p["end_on"]}',
                  f'Beginning balance: ${amount(totals["opening_balance_cents"])}    Ending balance: ${amount(totals["closing_balance_cents"])}',
                  f'Posted credits: ${amount(totals["printed_credit_cents"])}    Posted debits: ${amount(totals["printed_debit_cents"])}',
                  'Charges are debits; payments/refunds are credits. Balance owed = beginning + debits - credits.'
                  if account['account_basis'] == 'liability' else 'Beginning + deposits - withdrawals = ending. All rows posted.']
        for i, label in enumerate(header):
            c.drawString(32, 836 - i * 18, label)
        c.setFont('TalunBold', 10)
        for x, label in [(32, 'Date'), (108, 'Description'), (648, 'Debit'), (725, 'Credit')]:
            c.drawString(x, 697, label)
        y = 670
        for row in chunk:
            c.setFont('Talun', 8)
            c.drawString(32, y, row['date'])
            # Two lines reserve room for full bank descriptors without touching amounts.
            description = textwrap.wrap(row['description'], width=94)
            for i, label in enumerate(description):
                assert pdfmetrics.stringWidth(label, 'Talun', 8) < 520
                c.drawString(108, y - i * 11, label)
            cents = row['signed_amount_cents']
            c.drawRightString(697 if cents < 0 else 760, y, amount(abs(cents)))
            y -= 31
        c.setFont('Talun', 8)
        c.drawString(32, 32, f'{v1.FOOTER} | Fictional account | Page {page} of {len(chunks)}')
        c.showPage()
    c.save()


def phone(path, rows, month, capture):
    im = Image.new('RGB', (900, 1580), '#f5f5f2')
    d = ImageDraw.Draw(im)
    d.rectangle((0, 0, 900, 245), fill='#253f50')
    for y, label, size in [(28, '9:41', 24), (82, 'Bank of Guam-style DEMO', 34),
                           (142, 'Lina and Mateo Talun | ****6824', 25),
                           (193, f'2026-{month:02} activity | Capture {capture}', 22)]:
        d.text((32, y), label, font=raster_font(size, True), fill='white')
    y = 272
    for row in rows:
        d.text((32, y), f'{row["date"]}   {row["status"].upper()}', font=raster_font(21), fill='#606060')
        for j, label in enumerate(textwrap.wrap(row['description'], width=51)):
            d.text((32, y + 32 + j * 27), label, font=raster_font(23, True), fill='#202020')
        cents = row['signed_amount_cents']
        d.text((864, y + 92), f'{"-" if cents < 0 else "+"}${amount(abs(cents))}',
               font=raster_font(26, True), fill='#202020', anchor='ra')
        d.line((32, y + 132, 864, y + 132), fill='#d7d7d3', width=1)
        y += 150
    assert y < 1480
    d.text((32, 1500), v1.FOOTER, font=raster_font(21), fill='#555555')
    d.text((32, 1535), 'Fictional account; crop has no statement totals', font=raster_font(18), fill='#555555')
    im.save(path, optimize=True)


RECEIPTS = {
    'coupons': dict(items=[('Shirt', 4500, 'Clothing'), ('Child trousers', 2250, 'Clothing')],
                    discount_cents=1500, voucher_cents=0, total_cents=5250, new_money_cents=5250),
    'voucher': dict(items=[('Home fan', 12999, 'Household'), ('Shelf kit', 5489, 'Household')],
                    discount_cents=0, voucher_cents=15000, total_cents=18488, new_money_cents=3488),
    'mixed': dict(items=[('Rice and vegetables', 7342, 'Groceries'), ('Dish soap', 1800, 'Household'),
                        ('First aid supplies', 1200, 'Medical')],
                  discount_cents=0, voucher_cents=0, total_cents=10342, new_money_cents=10342),
}


def receipt(path, event, spec):
    paper = Image.new('RGB', (800, 1160), '#fffdf3')
    d = ImageDraw.Draw(paper)
    lines = [(event['merchant'].upper(), True), ('Tamuning, Guam | Register DEMO-04', False),
             (event['date'] + ' 18:24 | Lina Talun', False), ('Receipt SYN-' + event['receipt_key'].upper(), False),
             ('', False)]
    lines.extend((f'{label:<26} {amount(cents):>9}', False) for label, cents, _ in spec['items'])
    subtotal = sum(cents for _, cents, _ in spec['items'])
    lines.extend([('', False), (f'Subtotal                 ${amount(subtotal)}', False),
                  (f'Coupons / discounts     -${amount(spec["discount_cents"])}', False),
                  ('Tax                       $0.00', False),
                  (f'TOTAL                    ${amount(spec["total_cents"])}', True),
                  (f'Voucher / gift card      ${amount(spec["voucher_cents"])}', False),
                  (f'Debit card 7302          ${amount(spec["new_money_cents"])}', True),
                  ('Balance due               $0.00', False)])
    for i, (label, bold) in enumerate(lines):
        size = 27 if i == 0 else 23
        d.text((30, 35 + i * 48), label, font=raster_font(size, bold), fill='#222222')
    d.text((30, 1050), v1.FOOTER, font=raster_font(20), fill='#555555')
    d.text((30, 1090), 'Fictional purchase; all amounts invented', font=raster_font(19), fill='#555555')
    photo = Image.new('RGB', (980, 1320), '#9d9183')
    rotated = paper.rotate(1.1, resample=Image.Resampling.BICUBIC, expand=True, fillcolor='#9d9183')
    photo.paste(rotated, ((980 - rotated.width) // 2, (1320 - rotated.height) // 2))
    photo.save(path, quality=88, optimize=True)


def monthly_totals(events):
    """Economic totals once per event; duplicates only within the same account leg."""
    result = {}
    for m in range(1, 13):
        key = f'2026-{m:02}'
        selected = [e for e in events if e['date'].startswith(key)]
        categories = dict.fromkeys(CATEGORIES, 0)
        for e in selected:
            for allocation in e['category_allocations']:
                categories[allocation['category']] += allocation['spending_cents']
        duplicates = []
        receipt_matches = []
        for e in selected:
            for leg in e['account_legs']:
                posted = [ref for ref in e['representations'] if ref['leg_id'] == leg['leg_id']
                          and ref['status'] != 'pending']
                refs = [ref for ref in posted if ref['source_kind'] != 'receipt']
                receipt_matches.extend(dict(event_id=e['event_id'], **ref)
                                       for ref in posted if ref['source_kind'] == 'receipt')
                if len(refs) > 1:
                    duplicates.append(dict(event_id=e['event_id'], leg_id=leg['leg_id'],
                                           line_ids=[r['line_id'] for r in refs], copies=refs,
                                           duplicate_count=len(refs) - 1))
        transfers = [e for e in selected if e['event_kind'] == 'transfer_own_accounts']
        payments = [e for e in selected if e['event_kind'] == 'card_payment']
        result[key] = dict(spending_by_category_cents=categories, total_spending_cents=sum(categories.values()),
                           income_cents=sum(e['signed_amount_cents'] for e in selected if e['event_kind'] == 'income'),
                           transfers_cents=sum(-e['signed_amount_cents'] for e in transfers), transfer_count=len(transfers),
                           card_payments_cents=sum(-e['signed_amount_cents'] for e in payments),
                           event_count=len(selected), true_duplicate_count=sum(g['duplicate_count'] for g in duplicates),
                           duplicate_groups=duplicates, receipt_match_count=len(receipt_matches),
                           receipt_matches=receipt_matches)
    return result


def build(output):
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    events = ledger()
    by_id = {e['event_id']: e for e in events}
    documents = []

    def register(name, kind, accounts, document_period, rows, **extra):
        lines = []
        for i, row in enumerate(rows, 1):
            locator = row.get('locator', dict(page=(i - 1) // 18 + 1, row=(i - 1) % 18 + 1))
            line_id = f'{name}#line-{i:04}'
            line = {k: v for k, v in row.items() if k != 'locator'}
            line.update(line_id=line_id, locator=locator)
            lines.append(line)
            by_id[row['event_id']]['representations'].append(dict(document_path=name, line_id=line_id,
                leg_id=row['leg_id'], status=row['status'], source_kind=kind))
        path = output / name
        doc = dict(path=name, kind=kind, format=path.suffix[1:], account_keys=accounts,
                   period=document_period, sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                   size_bytes=path.stat().st_size, synthetic=True, lines=lines, **extra)
        documents.append(doc)
        return doc

    for account in ACCOUNTS:
        key = account['account_key']
        opening = account['opening_balance_cents']
        for m in range(1, 13):
            rows = account_rows(events, key, m)
            totals = reconciliation(rows, opening, account['account_basis'])
            opening = totals['closing_balance_cents']
            if key != 'bog' or m not in SCREEN_MONTHS:
                name = f'{key}-2026-{m:02}.pdf'
                statement(output / name, account, rows, m, totals)
                register(name, 'statement', [key], period(m), rows,
                         account_basis=account['account_basis'], printed_totals_cents=totals)
            if key == 'bog' and m in SCREEN_MONTHS | {3}:
                # Three chronological captures overlap by two rows. Capture 1 is taken
                # while day-12 market is pending; capture 2 shows its day-12 posting.
                # Stop capture 1 at the pending day-11 row; it cannot show future postings.
                end = len(rows)
                chunks = [rows[:6], rows[4:11], rows[9:end]]
                for capture, chunk in enumerate(chunks, 1):
                    shown = [dict(r, locator=dict(row=i + 1)) for i, r in enumerate(chunk)]
                    for row in shown:
                        if capture == 1 and row['event_id'].endswith('bog-market-3'):
                            row['date'] = (date.fromisoformat(row['date']) - timedelta(days=1)).isoformat()
                            row['status'] = 'pending'
                    name = f'bog-2026-{m:02}-phone-{capture}.png'
                    phone(output / name, shown, m, capture)
                    register(name, 'statement_screenshot', [key], period(m), shown,
                             printed_totals_cents=None, balance_scope='partial_activity_no_totals_printed')

    # First six months, all five accounts. Categories are suggestions only.
    csv_rows = []
    name = 'all-accounts-2026-01-to-06.csv'
    with (output / name).open('w', newline='', encoding='utf-8') as stream:
        writer = csv.writer(stream, lineterminator='\n')
        writer.writerow(['Date', 'Account', 'Description', 'Amount', 'Category', 'Status'])
        for m in range(1, 7):
            for account in ACCOUNTS:
                for i, row in enumerate(account_rows(events, account['account_key'], m)):
                    shown = dict(row)
                    shift = -(i % 3 + 1) if int(row['date'][-2:]) > 3 and i % 2 == 0 else 0
                    shown['date'] = (date.fromisoformat(row['date']) + timedelta(days=shift)).isoformat()
                    event = by_id[row['event_id']]
                    category = event['category'] or ('Transfer' if event['event_kind'] in {'transfer_own_accounts', 'card_payment'} else 'Income')
                    shown.update(source_category=category, locator=dict(row=len(csv_rows) + 2))
                    csv_rows.append(shown)
                    cents = row['signed_amount_cents']
                    writer.writerow([shown['date'], account['masked_identifier'] + ' ' + account['account_key'],
                                     row['description'], amount(cents).replace(',', ''), category, 'Posted'])
        writer.writerow([v1.FOOTER + ' | Fictional household and accounts'])
    register(name, 'multi_account_export', [a['account_key'] for a in ACCOUNTS],
             dict(start_on='2026-01-01', end_on='2026-06-30'), csv_rows,
             printed_totals_cents=None, amount_convention='negative debit/charge; positive credit, for each account')

    for event in events:
        if 'receipt_key' not in event:
            continue
        spec = RECEIPTS[event['receipt_key']]
        name = f'receipt-{event["receipt_key"]}-{event["date"]}.jpg'
        receipt(output / name, event, spec)
        row = dict(event_id=event['event_id'], leg_id=event['account_legs'][0]['leg_id'],
                   account_key='checking', date=event['date'], signed_amount_cents=-spec['new_money_cents'],
                   description=f'{event["merchant"]} debit tender', status='posted', locator=dict(tender='Debit card 7302'))
        details = dict(matching_bank_event_id=event['event_id'], new_money_cents=spec['new_money_cents'],
                       subtotal_cents=sum(c for _, c, _ in spec['items']), discount_cents=spec['discount_cents'],
                       voucher_cents=spec['voucher_cents'], total_cents=spec['total_cents'], tax_cents=0,
                       items=[dict(label=l, amount_cents=c, category=cat) for l, c, cat in spec['items']],
                       expected_category_allocations=event['category_allocations'])
        register(name, 'receipt', ['checking'], dict(start_on=event['date'], end_on=event['date']),
                 [row], printed_totals_cents=None, receipt=details)

    manifest = dict(schema_version='talun_year_v1', synthetic=True, currency='USD', household=v1.PERSON,
                    period=dict(start_on='2026-01-01', end_on='2026-12-31'),
                    generator='scripts/synthetic-documents/generate_year.py', categories=CATEGORIES,
                    raster_renderer=dict(platform=platform.system(), pillow=pillow_version, layout_engine='BASIC',
                                         **{name: features.version(name) for name in ('freetype2', 'raqm', 'jpg', 'zlib')}),
                    definitions=dict(
                        signed_amount_cents='Negative outflow/charge; positive income/refund. On transfers/payments the event amount is the originating negative leg; receiving leg is positive.',
                        spending='Purchases + fees + interest + cash withdrawals + family support - refunds. Category allocations sum to negative event amount; receipt vouchers excluded.',
                        transfers='Own-account transfers counted once by outgoing magnitude, excluded from spending and income. Card payments separately excluded.',
                        lines='Transaction/activity rows and receipt debit tender only; headers, item detail, coupons, vouchers, totals and footers are supporting evidence, not activity rows.',
                        duplicates='Extra non-pending bank/CSV/screenshot representations of the SAME account leg. Receipts are counted separately as receipt matches. Opposite transfer/payment legs, distinct purchases and pending-to-posted transitions are not true duplicates. Assigned to canonical event month.',
                        receipt_matches='Receipt debit tenders linked to bank events, scored separately from duplicate bank-source copies.',
                        distinct_purchases='Events sharing distinct_purchase_group are legitimate identical purchases; preserve each event even when date, amount and descriptor match.',
                        dates='Event date is canonical posted date. Screenshot pending date and CSV date may differ; use event date for monthly totals.',
                        identifiers='Stable fixture joins only; no permission to auto-match or infer identity. Event/leg IDs are never printed in source documents.'),
                    accounts=ACCOUNTS, document_count=len(documents), documents=documents, events=events,
                    expected_months=monthly_totals(events))
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
    print(f'Generated {len(documents)} documents, {len(events)} events, '
          f'{sum(m["true_duplicate_count"] for m in manifest["expected_months"].values())} duplicate representations')
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=DEFAULT_OUTPUT)
    build(parser.parse_args().output.resolve())
