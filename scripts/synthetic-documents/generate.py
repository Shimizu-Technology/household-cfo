#!/usr/bin/env python3
"""Generate only fictional upload fixtures; no network, app, model, or database use."""
import argparse
import calendar
import csv
from copy import deepcopy
from datetime import date, datetime
from decimal import Decimal
import hashlib
import io
import json
from pathlib import Path
import random
import subprocess
import tempfile
from xml.etree import ElementTree as ET
from zipfile import ZipFile, ZIP_DEFLATED

from PIL import Image, ImageDraw, ImageFilter, ImageFont
from openpyxl import Workbook, load_workbook
from openpyxl.styles import Alignment, Font, PatternFill
from openpyxl.utils import get_column_letter
import reportlab
from reportlab.lib import colors
from reportlab.lib.pagesizes import letter
from reportlab.lib.utils import ImageReader
from reportlab.pdfgen.canvas import Canvas

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OUTPUT = ROOT / 'api/test/fixtures/files/documents'
FOOTER = 'Synthetic test document'
PERSON = 'Lina and Mateo Talun (fictional household)'
STAMP = datetime(2026, 11, 1)
MONEY = '#,##0.00;(#,##0.00);"-"'
FONT_DIR = Path(reportlab.__file__).parent / 'fonts'


def money(cents):
    return f'{cents / 100:,.2f}'


def font(size, bold=False, mono=False):
    name = 'VeraBd.ttf' if bold else 'Vera.ttf'
    return ImageFont.truetype(str(FONT_DIR / name), size)


def event(account, month, n, day, description, cents, kind='purchase', status='posted'):
    return dict(event_id=f'{account}-2026{month:02}-{n:04}', account_key=account,
                posted_on=date(2026, month, day).isoformat(), description=description,
                signed_amount_cents=cents, event_type=kind, status=status,
                row_kind='informational' if status == 'pending' else 'posted',
                expected_spending_draft=status == 'posted' and cents < 0 and kind in ('purchase', 'fee', 'interest'),
                category={'fee': 'Bank fees', 'interest': 'Interest'}.get(kind))


def checking(month):
    # Stable identifiers across formats support dedupe tests without using real bank IDs.
    specs = [
        (1, 'Government of Guam DEMO payroll Lina', 210000, 'income'),
        (2, 'Rent - Talun family home', -125000, 'purchase'),
        (3, 'Payless Supermarkets - Mangilao', -10342, 'purchase'),
        (4, 'Shell - Upper Tumon', -4875, 'purchase'),
        (5, 'Island Table - Tamuning (includes tip)', -6720, 'purchase'),
        (6, 'Guam Power Authority GPA', -18645, 'purchase'),
        (7, 'Guam Waterworks Authority GWA', -5678, 'purchase'),
        (8, 'GTA - home internet', -8500, 'purchase'),
        (9, 'Docomo Pacific - mobile', -6500, 'purchase'),
        (10, 'Coast360 transfer to own savings 00002468', -20000, 'transfer'),
        (11, 'ATM withdrawal Mangilao', -10000, 'cash_withdrawal'),
        (12, 'Visa card payment 00009900', -25000, 'debt_payment'),
        (13, 'Ross Dress for Less Tamuning', -5525, 'purchase'),
        (14, 'Amazon Marketplace', -3899, 'purchase'),
        (15, 'Government of Guam DEMO payroll Lina', 210000, 'income'),
        (16, 'Tasi Services DEMO payroll Mateo', 165000, 'income'),
        (17, 'Cost-U-Less - Harmon', -14782, 'purchase'),
        (18, 'Kmart Tamuning', -3175, 'purchase'),
        (19, 'Mobil - Dededo', -5200, 'purchase'),
        (20, 'Jamba Juice - Micronesia Mall', -975, 'purchase'),
        (21, 'Port of Mocha - Hagatna', -625, 'purchase'),
        (22, "McDonald's - Tamuning", -1475, 'purchase'),
        (23, 'Netflix monthly subscription', -1549, 'purchase'),
        (24, 'Amazon refund order DEMO-8001', 1299, 'refund'),
        (25, 'Monthly service fee', -500, 'fee'),
        (28, 'Tasi Services DEMO payroll Mateo', 165000, 'income'),
    ]
    rows = [event('bog-00001234', month, n, *spec) for n, spec in enumerate(specs, 1)]
    # A visible change across months; receipt overlaps are intentionally September only.
    rows[16]['signed_amount_cents'] -= (month - 8) * 1000
    rows.append(event('bog-00001234', month, 27, calendar.monthrange(2026, month)[1],
                      'Port of Mocha - card authorization', -650, status='pending'))
    return rows


def totals(events, opening=0, basis='asset'):
    posted = [e for e in events if e['status'] == 'posted']
    credits = sum(max(e['signed_amount_cents'], 0) for e in posted)
    debits = sum(max(-e['signed_amount_cents'], 0) for e in posted)
    spending = [e for e in posted if e['expected_spending_draft']]
    return dict(opening_balance_cents=opening, printed_credit_cents=credits,
                printed_debit_cents=debits,
                closing_balance_cents=opening + (credits - debits) * (1 if basis == 'asset' else -1),
                spending_draft_total_cents=sum(abs(e['signed_amount_cents']) for e in spending),
                pending_display_total_cents=sum(abs(e['signed_amount_cents']) for e in events if e['status'] == 'pending'))


def base_pdf(path, title, subtitle):
    c = Canvas(str(path), pagesize=letter, invariant=1, pageCompression=1)
    c.setTitle(f'{title} - synthetic fixture')
    c.setAuthor('Household CFO synthetic corpus generator')
    c.setFillColor(colors.HexColor('#273d4b'))
    c.setFont('Helvetica-Bold', 22)
    c.drawString(42, 746, title)
    c.setFillColor(colors.black)
    c.setFont('Helvetica', 10)
    c.drawString(42, 725, subtitle)
    c.setStrokeColor(colors.HexColor('#718894'))
    c.line(42, 711, 570, 711)
    return c


def pdf_footer(c, page=1):
    c.setFont('Helvetica', 8)
    c.setFillColor(colors.HexColor('#555555'))
    c.drawString(42, 27, f'{FOOTER} | Fictional names and account numbers | Page {page}')


def statement_pdf(path, bank, account, events, opening, start, end, basis='asset', title='Monthly account statement'):
    t = totals(events, opening, basis)
    c = base_pdf(path, bank, title)
    lines = [PERSON, f'Account: {account} | Fictional test account',
             f'Statement period: {start} through {end}',
             f'Beginning balance: ${money(opening)}    Ending balance: ${money(t["closing_balance_cents"])}',
             f'Posted credits: ${money(t["printed_credit_cents"])}    Posted debits: ${money(t["printed_debit_cents"])}',
             f'Posted rows: {sum(e["status"] == "posted" for e in events)} | Pending excluded from totals']
    for i, line in enumerate(lines):
        c.drawString(42, 692 - i * 16, line)
    y = 577
    c.setFont('Helvetica-Bold', 9)
    for x, label in [(42, 'Date'), (103, 'Description'), (454, 'Debit'), (531, 'Credit')]:
        c.drawString(x, y, label)
    c.line(42, y - 6, 570, y - 6)
    c.setFont('Helvetica', 8.5)
    y -= 23
    for e in events:
        c.drawString(42, y, e['posted_on'][5:].replace('-', '/'))
        label = e['description'] + (' [PENDING]' if e['status'] == 'pending' else '')
        c.drawString(103, y, label)
        amount = e['signed_amount_cents']
        c.drawRightString(490 if amount < 0 else 570, y, money(abs(amount)))
        y -= 16
    c.line(42, y + 4, 570, y + 4)
    c.setFont('Helvetica-Bold', 9)
    c.drawString(42, y - 13, 'Posted totals')
    c.drawRightString(490, y - 13, money(t['printed_debit_cents']))
    c.drawRightString(570, y - 13, money(t['printed_credit_cents']))
    c.setFont('Helvetica', 8)
    formula = 'Beginning + credits - debits = ending' if basis == 'asset' else 'Prior balance + charges - payments/refunds = new balance'
    c.drawString(42, y - 33, formula)
    pdf_footer(c)
    c.save()


LAYOUTS = [
    ['Date', 'Description', 'Withdrawal', 'Deposit', 'Status', 'Reference'],
    ['Posted Date', 'Payee', 'Debit Amount', 'Credit Amount', 'Status', 'Reference'],
    ['Transaction Date', 'Description', 'Amount', 'Transaction Type', 'Status', 'Reference'],
]


def table_rows(events, layout):
    rows = []
    for e in events:
        value = e['signed_amount_cents']
        head = [e['posted_on'], e['description']]
        amounts = [abs(value) / 100, 'Debit' if value < 0 else 'Credit'] if layout == 2 else [abs(value) / 100 if value < 0 else None, value / 100 if value > 0 else None]
        rows.append(head + amounts + [e['status'].title(), e['event_id']])
    return rows


def statement_csv(path, events, layout):
    with path.open('w', newline='', encoding='utf-8') as f:
        writer = csv.writer(f, lineterminator='\n')
        writer.writerow(LAYOUTS[layout])
        for row in table_rows(events, layout):
            writer.writerow([f'{v:.2f}' if isinstance(v, float) else v for v in row])
        writer.writerow([FOOTER + ' | Fictional household and account numbers; no real banking data'])


def style_sheet(s, header=1, widths=None):
    s.sheet_view.showGridLines = False
    s.freeze_panes = f'C{header + 1}'
    for cell in s[header]:
        cell.fill = PatternFill('solid', fgColor='314D5A')
        cell.font = Font(name='Arial', size=10, bold=True, color='FFFFFF')
        cell.alignment = Alignment(vertical='center', wrap_text=True)
    s.row_dimensions[header].height = 30
    for row in s.iter_rows(min_row=header + 1):
        for cell in row:
            cell.font = Font(name='Arial', size=10)
            cell.alignment = Alignment(vertical='center')
            if isinstance(cell.value, (float, int)):
                cell.number_format = MONEY
            if isinstance(cell.value, (date, datetime)):
                cell.number_format = 'mm/dd/yyyy'
    for col, width in (widths or {'A': 18, 'B': 58, 'C': 18, 'D': 18, 'E': 18, 'F': 42, 'G': 54}).items():
        s.column_dimensions[col].width = width
    s.oddFooter.center.text = FOOTER
    s.sheet_properties.pageSetUpPr.fitToPage = True
    s.page_setup.orientation = 'landscape'
    s.page_setup.paperSize = s.PAPERSIZE_A3 if s.max_column > 10 else s.PAPERSIZE_A4
    s.page_setup.fitToWidth = 1
    s.page_setup.fitToHeight = 0
    s.print_title_rows = f'1:{header}'
    s.print_area = s.dimensions


def save_book(w, path, caches=None):
    """Stable ZIP metadata; optionally insert independently calculated formula caches."""
    w.properties.created = STAMP
    w.properties.modified = STAMP
    w.properties.creator = 'Household CFO synthetic corpus'
    w.save(path)
    with ZipFile(path) as z:
        entries = {n: z.read(n) for n in z.namelist()}
    ns = {'s': 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'}
    for sheet, values in (caches or {}).items():
        name = f'xl/worksheets/sheet{sheet}.xml'
        root = ET.fromstring(entries[name])
        for c in root.findall('.//s:c', ns):
            if c.attrib['r'] in values:
                c.find('s:v', ns).text = str(values[c.attrib['r']])
        entries[name] = ET.tostring(root, encoding='utf-8', xml_declaration=True)
    # openpyxl updates core modified time during save; normalize it too.
    import re
    entries['docProps/core.xml'] = re.sub(rb'(<dcterms:modified[^>]*>).*?(</dcterms:modified>)', rb'\g<1>2026-11-01T00:00:00Z\2', entries['docProps/core.xml'])
    with ZipFile(path, 'w', ZIP_DEFLATED) as z:
        for name in sorted(entries):
            from zipfile import ZipInfo
            info = ZipInfo(name, (2026, 11, 1, 0, 0, 0))
            info.compress_type = ZIP_DEFLATED
            z.writestr(info, entries[name])


def statement_xlsx(path, events, layout):
    w = Workbook()
    s = w.active
    s.title = 'Transactions'
    s.append(LAYOUTS[layout])
    for row in table_rows(events, layout):
        row[0] = date.fromisoformat(row[0])
        s.append(row)
    s.append([FOOTER + ' | All household names, references and account numbers are fictional.'])
    style_sheet(s)
    s.auto_filter.ref = f'A1:F{len(events) + 1}'
    save_book(w, path)


def scanned_pdf(path, source):
    with tempfile.TemporaryDirectory(prefix='hcfo-synthetic-scan-') as tmp:
        prefix = Path(tmp) / 'scan'
        subprocess.run(['pdftoppm', '-scale-to', '1600', '-singlefile', '-png', str(source), str(prefix)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        im = Image.open(prefix.with_suffix('.png')).convert('L')
        rng = random.Random(210)
        draw = ImageDraw.Draw(im)
        for _ in range(14000):
            x, y = rng.randrange(im.width), rng.randrange(im.height)
            if im.getpixel((x, y)) > 200:
                draw.point((x, y), fill=rng.randrange(205, 250))
        im = im.rotate(0.65, resample=Image.Resampling.BICUBIC, expand=False, fillcolor=248)
        im = im.filter(ImageFilter.GaussianBlur(0.25))
        c = Canvas(str(path), pagesize=letter, invariant=1)
        c.drawImage(ImageReader(im), 0, 0, width=612, height=792)
        c.save()


def receipt_image(path, merchant, day, items, tip=0, angle=1.2):
    """Photographed paper on a neutral desk, with reproducible lighting and grain."""
    im = Image.new('RGB', (920, 1200), '#b0a395')
    paper = Image.new('RGBA', (720, 1030), '#fffdf3')
    d = ImageDraw.Draw(paper)
    d.text((38, 40), merchant, font=font(28, True), fill='#222222')
    d.text((38, 93), 'Guam | Register DEMO-04', font=font(19, mono=True), fill='#333333')
    d.text((38, 128), f'{day}  18:24 | Lina Talun', font=font(19, mono=True), fill='#333333')
    d.text((38, 163), 'Receipt SYN-2026-0900', font=font(19, mono=True), fill='#333333')
    d.line((38, 211, 680, 211), fill='#777777', width=2)
    y = 245
    for item in items:
        d.text((38, y), item['label'], font=font(22, mono=True), fill='#222222')
        d.text((677, y), money(item['amount_cents']), font=font(22, mono=True), fill='#222222', anchor='ra')
        y += 52
    subtotal = sum(i['amount_cents'] for i in items)
    y += 30
    for label, value in [('Subtotal', subtotal), ('Tax', 0), ('Tip', tip), ('TOTAL', subtotal + tip)]:
        d.text((38, y), label, font=font(24, bold=label == 'TOTAL'), fill='#111111')
        d.text((677, y), '$' + money(value), font=font(24, bold=label == 'TOTAL'), fill='#111111', anchor='ra')
        y += 47
    d.text((38, y + 24), 'Visa ****1234 | Approved DEMO', font=font(19, mono=True), fill='#333333')
    d.text((38, 953), FOOTER, font=font(18), fill='#555555')
    d.text((38, 982), 'Fictional purchase - no real customer data', font=font(16), fill='#555555')
    paper = paper.rotate(angle, resample=Image.Resampling.BICUBIC, expand=True)
    shadow = Image.new('RGBA', im.size)
    sd = ImageDraw.Draw(shadow)
    sd.rectangle((110, 91, 835, 1123), fill=(25, 20, 15, 75))
    im = Image.alpha_composite(im.convert('RGBA'), shadow.filter(ImageFilter.GaussianBlur(15)))
    im.alpha_composite(paper, (80, 70))
    im.convert('RGB').save(path, quality=86, optimize=True)


def phone_image(path, events):
    im = Image.new('RGB', (780, 1536), '#f5f5f2')
    d = ImageDraw.Draw(im)
    d.rectangle((0, 0, 780, 250), fill='#253f50')
    d.text((40, 28), '9:41', font=font(24, True), fill='white')
    d.text((40, 90), 'Bank of Guam', font=font(36, True), fill='white')
    d.text((40, 157), 'Checking ****1234 | Lina Talun', font=font(24), fill='white')
    d.text((40, 203), 'September 2026 activity', font=font(22), fill='white')
    y = 282
    for e in reversed(events):
        d.text((38, y), e['posted_on'], font=font(21), fill='#606060')
        description = e['description'].replace(' - card authorization', '').replace('Government of Guam DEMO payroll Lina', 'DEMO Payroll - Lina')
        d.text((38, y + 37), description, font=font(22, True), fill='#202020')
        amount = e['signed_amount_cents']
        d.text((742, y + 76), ('-' if amount < 0 else '+') + '$' + money(abs(amount)), font=font(25, True), fill='#202020', anchor='ra')
        d.text((38, y + 80), e['status'].title(), font=font(20), fill='#555555')
        d.line((38, y + 123, 742, y + 123), fill='#d7d7d3', width=1)
        y += 147
    d.text((38, 1473), FOOTER, font=font(20), fill='#555555')
    d.text((38, 1504), 'Fictional account and household', font=font(17), fill='#555555')
    im.save(path, optimize=True)


def paystub(path, employer, period, pay_on, gross, deductions, ytd_multiplier):
    net = gross - sum(deductions.values())
    c = base_pdf(path, employer, 'Earnings statement | Employee copy | Fictional employer payroll')
    lines = [f'Employee: {"Lina" if "Government" in employer else "Mateo"} Talun (fictional)',
             'Employee ID: SYN-000042 | Deposit to DEMO checking ****1234',
             f'Pay period: {period[0]} through {period[1]}', f'Pay date: {pay_on}',
             'Pay frequency: Semi-monthly (24 periods/year)']
    for i, line in enumerate(lines):
        c.drawString(42, 683 - i * 22, line)
    c.setFont('Helvetica-Bold', 11)
    for x, label in [(42, 'Earnings / deductions'), (390, 'Current'), (510, 'Year to date')]:
        c.drawString(x, 540, label)
    c.line(42, 527, 570, 527)
    y = 500
    c.setFont('Helvetica', 11)
    for label, value in [('Regular gross pay', gross), *deductions.items(), ('Net deposit', net)]:
        c.drawString(42, y, label)
        c.drawRightString(440, y, '$' + money(value))
        c.drawRightString(570, y, '$' + money(value * ytd_multiplier))
        y -= 32
    c.setFont('Helvetica-Bold', 12)
    c.drawString(42, 200, f'Gross ${money(gross)} - deductions ${money(sum(deductions.values()))} = net ${money(net)}')
    pdf_footer(c)
    c.save()
    return dict(employee_name=('Lina' if 'Government' in employer else 'Mateo') + ' Talun',
                employer=employer, cadence='semi_monthly', gross_cents=gross,
                deductions_cents=deductions, total_deductions_cents=sum(deductions.values()),
                net_cents=net, pay_on=pay_on, ytd_period_count=ytd_multiplier,
                ytd_gross_cents=gross*ytd_multiplier, ytd_net_cents=net*ytd_multiplier)


BUDGET_HEADERS = ['type', 'label', 'amount', 'cadence', 'category', 'payment', 'notes']
BUDGET_ROWS = [
    ['income_source', 'Lina government net pay', 4200, 'monthly', 'job', None, 'Two fictional net deposits of $2,100'],
    ['income_source', 'Mateo services net pay', 3300, 'monthly', 'job', None, 'Two fictional net deposits of $1,650'],
    ['expense_item', 'Rent', 1250, 'monthly', 'non_discretionary', None, 'Family home'],
    ['expense_item', 'Utilities and communications', 400, 'monthly', 'non_discretionary', None, 'Power, water, internet and mobile'],
    ['expense_item', 'Groceries', 650, 'monthly', 'discretionary', None, 'Food only; tobacco separate'],
    ['expense_item', 'Dining out', 180, 'monthly', 'discretionary', None, 'Includes restaurant tips'],
    ['expense_item', 'Transportation', 220, 'monthly', 'non_discretionary', None, 'Fuel and bus fares'],
    ['expense_item', 'Car maintenance fund', 100, 'monthly', 'sinking_expected', None, 'Routine repairs'],
    ['expense_item', 'Medical buffer', 150, 'monthly', 'sinking_unexpected', None, 'Unexpected family costs'],
    ['account', 'Emergency savings', 5000, 'one_time', 'emergency_fund', None, 'Snapshot on September 30, 2026'],
    ['debt', 'Mainland Visa', 3400, 'monthly', 'credit_card', 175, 'Balance is a snapshot; payment is monthly'],
    ['goal', 'Emergency cushion', 500, 'one_time', 'savings', None, 'Fictional proposed target'],
]


def budget_items(rows, sheet, first_row):
    return [dict(type=r[0], label=r[1], amount_cents=round(r[2]*100), cadence=r[3],
                 category=r[4], payment_cents=round(r[5]*100) if r[5] is not None else None,
                 notes=r[6], locator={'sheet': sheet, 'row': first_row+i}) for i, r in enumerate(rows)]


def annual_budget(path):
    w = Workbook()
    s = w.active
    s.title = 'Household CFO Budget'
    s.append(BUDGET_HEADERS)
    for row in BUDGET_ROWS:
        s.append(row)
    s.append([FOOTER, 'Lina and Mateo Talun; annual plan January-December 2026'])
    style_sheet(s)
    schedule = w.create_sheet('2026 monthly plan')
    schedule.append(['2026 household plan | USD | fictional household'])
    schedule.append(['Label'] + [date(2026, m, 1) for m in range(1, 13)] + ['Annual total'])
    cache = {}
    for i, row in enumerate(BUDGET_ROWS[:9], 3):
        schedule.append([row[1]] + [row[2]] * 12 + [f'=SUM(B{i}:M{i})'])
        cache[f'N{i}'] = row[2] * 12
    schedule.append([FOOTER, 'Monthly net income and planned expenses only; account/debt snapshots excluded.'])
    style_sheet(schedule, 2, {'A': 38, **{get_column_letter(i): 15 for i in range(2, 15)}})
    for c in schedule[2][1:13]:
        c.number_format = 'mmm-yy'
    for row in schedule.iter_rows(min_row=3, max_row=11):
        row[-1].font = Font(name='Arial', size=10, color='000000')
    save_book(w, path, {2: cache})
    return budget_items(BUDGET_ROWS, s.title, 2)


def messy_budget(path):
    w = Workbook()
    s = w.active
    s.title = 'Family plan 2026'
    s.merge_cells('A1:G1')
    s['A1'] = 'Talun household - working annual budget 2026 (fictional)'
    s.merge_cells('A2:G2')
    s['A2'] = 'Notes from September: grocery plan excludes tobacco. Review the car fund next month.'
    s.merge_cells('A4:G4')
    s['A4'] = 'Current approved monthly plan - not historical transactions'
    for col, value in enumerate(BUDGET_HEADERS, 1):
        s.cell(6, col, value)
    for row in BUDGET_ROWS:
        s.append(row)
    s.append([FOOTER, 'Fictional household; notes and archive rows are not new setup items.'])
    style_sheet(s, 6)
    archive = w.create_sheet('Planning archive')
    archive.merge_cells('A1:G1')
    archive['A1'] = 'Archived planning estimates - not purchases or current monthly budgets'
    archive.append(['Archived on', 'Envelope', 'Estimate USD', 'Revision', 'Owner', 'State', 'Note'])
    for i in range(600):
        # Deliberately NOT a date/description/amount statement table or type/label setup table.
        # A model must not turn draft estimates into 600 purchases or setup items.
        archive.append([date(2026, 1 + i % 9, 1 + i % 27), ['Food', 'Car', 'School', 'Family'][i % 4],
                        (1000 + i % 71 * 125) / 100, i + 1, 'Lina' if i % 2 else 'Mateo',
                        'superseded', 'Planning note only; replaced by current plan'])
    archive.append([FOOTER, '600 archived estimates; no actual bank transactions.'])
    style_sheet(archive, 2, {'A': 18, 'B': 25, 'C': 20, 'D': 13, 'E': 15, 'F': 20, 'G': 62})
    notes = w.create_sheet('Notes and reminders')
    notes.merge_cells('A1:D1')
    notes['A1'] = 'Family notes - no new financial items'
    notes.append(['Topic', 'Note'])
    notes.append(['Groceries', 'Payless receipts may include cigarettes; separate tobacco from food.'])
    notes.append(['Goal', 'Emergency cushion is a proposed target; Lina still needs to confirm.'])
    notes.append([FOOTER, 'All entries and people are fictional.'])
    style_sheet(notes, 2, {'A': 26, 'B': 92, 'C': 16, 'D': 16})
    save_book(w, path)
    return budget_items(BUDGET_ROWS, s.title, 7)


def build(output):
    output.mkdir(parents=True, exist_ok=True)
    documents = []

    def add(filename, kind, *, events=None, opening=0, basis='asset', period=None, **extra):
        events = deepcopy(events or [])
        doc = dict(filename=filename, kind=kind, format=Path(filename).suffix[1:],
                   currency='USD', synthetic=True, period_start_on=period[0] if period else None,
                   period_end_on=period[1] if period else None,
                   months=sorted({e['posted_on'][:7] for e in events}) if events else extra.pop('months', []),
                   expected_source_event_count=len(events),
                   expected_posted_event_count=sum(e['status'] == 'posted' for e in events),
                   expected_spending_draft_count=sum(e['expected_spending_draft'] for e in events),
                   expected_events=events, totals_cents=totals(events, opening, basis),
                   account_basis=basis, expected_items=[], expected_item_count=0)
        doc.update(extra)
        documents.append(doc)
        return doc

    opening = 275000
    for month in [8, 9, 10]:
        events = checking(month)
        period = (f'2026-{month:02}-01', f'2026-{month:02}-{calendar.monthrange(2026, month)[1]}')
        name = f'bank-of-guam-2026-{month:02}'
        statement_pdf(output / f'{name}.pdf', 'Bank of Guam', 'DEMO 00001234', events, opening, *period)
        statement_csv(output / f'{name}.csv', events, 0)
        for ext in ['pdf', 'csv']:
            add(f'{name}.{ext}', 'statement', events=events, opening=opening, period=period,
                overlap_group=name, csv_layout=LAYOUTS[0] if ext == 'csv' else None,
                institution='Bank of Guam', fictional_account='00001234')
        opening = totals(events, opening)['closing_balance_cents']

    bp = [event('bankpacific-00005678', 9, 1, 2, 'Transfer from own DEMO account 00006666', 30000, 'transfer'),
          event('bankpacific-00005678', 9, 2, 11, 'Cost-U-Less - Harmon', -8246),
          event('bankpacific-00005678', 9, 3, 20, 'Interest credit', 37, 'interest'),
          event('bankpacific-00005678', 9, 4, 23, 'ATM withdrawal Dededo', -4000, 'cash_withdrawal')]
    for ext in ['pdf', 'csv']:
        name = f'bankpacific-2026-09.{ext}'
        if ext == 'pdf':
            statement_pdf(output/name, 'BankPacific', 'DEMO 00005678', bp, 80000, '2026-09-01', '2026-09-30')
        else:
            statement_csv(output/name, bp, 1)
        add(name, 'statement', events=bp, opening=80000, period=('2026-09-01', '2026-09-30'),
            overlap_group='bankpacific-2026-09', csv_layout=LAYOUTS[1] if ext == 'csv' else None,
            institution='BankPacific', fictional_account='00005678')

    coast = [event('coast360-00002468', 10, 1, 10, 'Transfer from own Bank of Guam 00001234', 20000, 'transfer'),
             event('coast360-00002468', 10, 2, 14, 'GTA mobile prepaid', -2500),
             event('coast360-00002468', 10, 3, 28, 'Monthly dividend credit', 85, 'income'),
             event('coast360-00002468', 10, 4, 31, 'Debit card replacement fee', -500, 'fee')]
    coast[2]['allowed_event_types'] = ['income', 'interest']  # Credit-union dividends are earnings; both classifications are valid.
    period = ('2026-10-01', '2026-10-31')
    statement_pdf(output/'coast360-2026-10.pdf', 'Coast360 Federal Credit Union', 'DEMO 00002468', coast, 400000, *period)
    scanned_pdf(output/'coast360-2026-10-scanned.pdf', output/'coast360-2026-10.pdf')
    statement_csv(output/'coast360-2026-10.csv', coast, 2)
    statement_xlsx(output/'coast360-2026-10.xlsx', coast, 2)
    for suffix in ['.pdf', '-scanned.pdf', '.csv', '.xlsx']:
        add('coast360-2026-10'+suffix, 'statement', events=coast, opening=400000, period=period,
            overlap_group='coast360-2026-10', institution='Coast360 Federal Credit Union',
            fictional_account='00002468', raster_only=suffix == '-scanned.pdf',
            csv_layout=LAYOUTS[2] if suffix in ('.csv', '.xlsx') else None)

    card = [event('visa-00009900', 9, 1, 6, 'Amazon Marketplace', -11899),
            event('visa-00009900', 9, 2, 12, 'Payment from Bank of Guam 00001234', 25000, 'debt_payment'),
            event('visa-00009900', 9, 3, 18, 'Ross Dress for Less Tamuning', -8425),
            event('visa-00009900', 9, 4, 24, 'Amazon merchandise refund', 1999, 'refund'),
            event('visa-00009900', 9, 5, 30, 'Purchase interest charge', -2175, 'interest')]
    statement_pdf(output/'mainland-visa-2026-09.pdf', 'Mainland Visa - DEMO issuer', 'DEMO 00009900', card, 340000,
                  '2026-09-01', '2026-09-30', basis='liability', title='Credit card billing statement')
    add('mainland-visa-2026-09.pdf', 'statement', events=card, opening=340000, basis='liability',
        period=('2026-09-01', '2026-09-30'), fictional_account='00009900')

    retirement = [event('retirement-00007777', 8, 1, 15, 'Employee retirement contribution', 20000, 'transfer'),
                  event('retirement-00007777', 8, 2, 15, 'Employer contribution', 10000, 'income'),
                  event('retirement-00007777', 9, 1, 15, 'Employee retirement contribution', 20000, 'transfer'),
                  event('retirement-00007777', 9, 2, 15, 'Employer contribution', 10000, 'income'),
                  event('retirement-00007777', 10, 1, 15, 'Employee retirement contribution', 20000, 'transfer'),
                  event('retirement-00007777', 10, 2, 15, 'Employer contribution', 10000, 'income'),
                  event('retirement-00007777', 10, 3, 31, 'Cash dividend distribution', 12450, 'income')]
    statement_pdf(output/'asc-style-retirement-2026-08-to-10.pdf', 'ASC Trust-style DEMO retirement', 'DEMO 00007777',
                  retirement, 2500000, '2026-08-01', '2026-10-31', title='Retirement cash activity | No market value changes in this fixture')
    add('asc-style-retirement-2026-08-to-10.pdf', 'retirement_statement', events=retirement, opening=2500000,
        period=('2026-08-01', '2026-10-31'), fictional_account='00007777')

    selected = checking(9)[-7:]
    phone_image(output/'bank-of-guam-2026-09-phone.png', selected)
    add('bank-of-guam-2026-09-phone.png', 'statement_screenshot', events=selected,
        period=('2026-09-20', '2026-09-30'), overlap_group='bank-of-guam-2026-09',
        balance_scope='partial_activity_no_balance_printed')
    # A screenshot has no printed account reconciliation: avoid implying a zero opening balance.
    documents[-1]['totals_cents']['opening_balance_cents'] = None
    documents[-1]['totals_cents']['closing_balance_cents'] = None

    receipt_specs = [
        ('payless', 'Payless Supermarkets', 3, [('Rice 5 lb', 1299, 'Groceries'), ('Chicken thighs', 1648, 'Groceries'),
          ('Milk 1 gallon', 899, 'Groceries'), ('Produce assorted', 2346, 'Groceries'), ('Bread and eggs', 2350, 'Groceries'),
          ('Cigarettes 1 pack', 1800, 'Tobacco')], 0),
        ('shell', 'Shell - Upper Tumon', 4, [('Regular fuel 12.500 gal', 4875, 'Transportation')], 0),
        ('restaurant', 'Island Table - Tamuning', 5, [('Grilled fish plate', 2495, 'Dining out'), ('Chicken plate', 2195, 'Dining out'),
          ('Iced tea x 2', 630, 'Dining out')], 1400),
        ('ross', 'Ross Dress for Less', 13, [('Blouse', 1699, 'Clothing'), ('Kids shorts', 1299, 'Clothing'),
          ('Bath towels', 2527, 'Household supplies')], 0),
    ]
    for i, (slug, merchant, day, values, tip) in enumerate(receipt_specs):
        items = [dict(label=label, amount_cents=amount, category=cat) for label, amount, cat in values]
        filename = f'receipt-{slug}-2026-09-{day:02}.jpg'
        receipt_image(output/filename, merchant, f'09/{day:02}/2026', items, tip, angle=[1.2, -1.0, 0.7, -1.3][i])
        linked = next(e for e in checking(9) if e['posted_on'] == f'2026-09-{day:02}')
        doc = add(filename, 'receipt', events=[linked], period=(linked['posted_on'], linked['posted_on']),
                  overlap_group='bank-of-guam-2026-09', receipt_items=items, subtotal_cents=sum(v['amount_cents'] for v in items),
                  tax_cents=0, tip_cents=tip, receipt_total_cents=sum(v['amount_cents'] for v in items)+tip)
        doc['totals_cents']['opening_balance_cents'] = None
        doc['totals_cents']['closing_balance_cents'] = None
        doc['expected_category_splits'] = items + ([dict(label='Tip', amount_cents=tip, category='Dining out')] if tip else [])

    for name, employer, pay_on, gross, deductions, multiplier in [
        ('government', 'Government of Guam - DEMO payroll', '2026-09-15', 280000,
         {'Withholding tax': 28000, 'Social Security': 17360, 'Medicare': 4060, 'Retirement': 14000, 'Health insurance': 6580}, 18),
        ('private', 'Tasi Services - DEMO private employer', '2026-09-16', 220000,
         {'Withholding tax': 18000, 'Social Security': 13640, 'Medicare': 3190, 'Retirement': 11000, 'Health insurance': 9170}, 18),
    ]:
        filename = f'paystub-{name}-2026-09.pdf'
        details = paystub(output/filename, employer, ('2026-09-01', '2026-09-15'), pay_on, gross, deductions, multiplier)
        item = dict(type='income_source', label=details['employee_name']+' net pay',
                    amount_cents=details['net_cents'], cadence='semi_monthly', category='job',
                    monthly_equivalent_cents=details['net_cents'] * 2)
        add(filename, 'pay_stub', period=('2026-09-01', '2026-09-15'), months=['2026-09'],
            paystub=details, expected_items=[item], expected_item_count=1,
            linked_payroll_event_id=next(e['event_id'] for e in checking(9) if e['event_type']=='income' and e['posted_on']==pay_on))

    for name, builder in [('budget-annual-2026.xlsx', annual_budget), ('budget-messy-600-rows-2026.xlsx', messy_budget)]:
        items = builder(output/name)
        add(name, 'budget', period=('2026-01-01', '2026-12-31'),
            months=[f'2026-{m:02}' for m in range(1, 13)], expected_items=items, expected_item_count=len(items),
            expected_budget_totals_cents=dict(monthly_income=750000, monthly_expenses=295000,
                annual_income=9000000, annual_expenses=3540000, monthly_debt_payment=17500),
            archive_row_count=600 if 'messy' in name else 0)

    large = []
    merchants = ['Payless Supermarkets', 'Shell - Upper Tumon', 'Port of Mocha', 'Cost-U-Less - Harmon', 'GTA prepaid']
    for i in range(1000):
        cents = -(100 + i * 37 % 19000)
        kind = 'purchase'
        label = merchants[i % len(merchants)]
        if i % 100 == 0:
            cents, kind, label = 300000, 'income', 'DEMO settlement payroll'
        elif i % 100 == 1:
            cents, kind, label = -20000, 'transfer', 'Transfer to own savings'
        elif i % 100 == 2:
            cents, kind, label = -25000, 'debt_payment', 'Visa payment'
        elif i % 100 == 3:
            cents, kind, label = 999, 'refund', 'Payless merchandise refund'
        e = event('stress-00008888', 10, i+1, 1 + i * 31 // 1000, label, cents, kind)
        e['description'] += f' | ref SYN{i+1:04}'
        large.append(e)
    for ext in ['csv', 'xlsx']:
        name = f'statement-1000-rows-2026-10.{ext}'
        (statement_csv if ext == 'csv' else statement_xlsx)(output/name, large, 1)
        add(name, 'statement', events=large, opening=12000000, period=('2026-10-01', '2026-10-31'),
            overlap_group='statement-1000-rows-2026-10', csv_layout=LAYOUTS[1],
            fictional_account='00008888', stress_fixture=True)

    for doc in documents:
        path = output/doc['filename']
        doc['sha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
        doc['size_bytes'] = path.stat().st_size
        doc['totals_origin'] = 'printed_on_document' if doc['format'] == 'pdf' and doc['kind'] != 'pay_stub' else 'derived_from_expected_rows'
        for i, e in enumerate(doc['expected_events']):
            if doc['format'] in ('csv', 'xlsx'):
                e['locator'] = {'row': i+2, **({'sheet_index': 0, 'sheet': 'Transactions'} if doc['format']=='xlsx' else {})}
            elif doc['format'] == 'pdf':
                e['locator'] = {'page': 1, 'row': i+1}
            else:
                physical_index = len(doc['expected_events']) - 1 - i if doc['kind'] == 'statement_screenshot' else i
                e['locator'] = {'extraction_index': physical_index, 'row': physical_index+1}
        if doc['kind'] in ('budget', 'pay_stub'):
            # No source transaction events: these are setup proposals, not spending.
            doc['totals_cents'] = {}
    manifest = dict(schema_version=1, generated_for='W2 Household CFO round4 outcome 1',
                    synthetic=True, generator='scripts/synthetic-documents/generate.py',
                    definitions=dict(source_event_count='Transaction/activity rows only, including pending; excludes printed headers, totals, and footers.',
                      spending_draft_count='Posted purchases, fees and interest only; refunds, income, transfers, cash withdrawals, card payments and pending rows excluded.',
                      signed_amount_cents='Negative is money out / charge; positive is money in / payment credit. Liability closing = opening - signed movements.',
                      budget_items='Current financial setup proposals only; archive estimates and monthly schedules are supporting evidence, not duplicate items. Faithful optional profile notes are not counted as financial items.',
                      identifiers='event_id is a fixture join key, not an application deduplication contract.'),
                    document_count=len(documents), documents=documents)
    (output/'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
    print(f'Generated {len(documents)} documents ({sum(d["size_bytes"] for d in documents):,} bytes), plus manifest.')


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output', type=Path, default=DEFAULT_OUTPUT)
    args = p.parse_args()
    build(args.output.resolve())
