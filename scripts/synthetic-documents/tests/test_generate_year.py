"""Independent arithmetic/source checks for the fictional year scorecard inputs."""
from collections import Counter, defaultdict
from copy import deepcopy
import csv
from decimal import Decimal
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

from PIL import Image

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import generate_year as year  # noqa: E402

ROOT = SCRIPTS.parents[1] / 'api/test/fixtures/files/documents/talun-year'

# Reviewed answer-key constants in cents, also printed in the year README.
EXPECTED_CATEGORIES = ['Housing', 'Groceries', 'Dining', 'Transport', 'Utilities', 'Phone', 'Subscriptions', 'Childcare', 'Medical', 'Household', 'Clothing', 'Cash', 'Family support', 'Fees', 'Interest']
# Month: spending, income, own transfers, card payments, category amounts in the order above.
EXPECTED_MONTHS = {
    '2026-01': (358586, 768500, 82500, 25000,
        [125000, 58859, 12745, 11661, 32823, 6500, 1399, 42000, 0, 11199, 8425, 32000, 12500, 1300, 2175]),
    '2026-02': (366838, 750000, 82500, 25000,
        [125000, 59050, 12095, 11672, 32823, 6500, 1399, 42000, 8700, 11199, 8425, 32000, 12500, 1300, 2175]),
    '2026-03': (360591, 782750, 82500, 25000,
        [125000, 59241, 12095, 11683, 32823, 6500, 1399, 42000, 0, 11199, 10676, 32000, 12500, 1300, 2175]),
    '2026-04': (339897, 750000, 82500, 25000,
        [125000, 59432, 12095, 11694, 14178, 6500, 1399, 42000, 0, 11199, 8425, 32000, 12500, 1300, 2175]),
    '2026-05': (378889, 750000, 82500, 25000,
        [125000, 59623, 12095, 11705, 51468, 6500, 1399, 42000, 0, 11199, 8425, 32000, 12500, 2800, 2175]),
    '2026-06': (371534, 759600, 82500, 25000,
        [125000, 59814, 12095, 11716, 32823, 6500, 1399, 42000, 9100, 14687, 8425, 32000, 12500, 1300, 2175]),
    '2026-07': (359348, 750000, 82500, 25000,
        [125000, 60005, 12095, 11727, 32823, 6500, 1599, 42000, 0, 11199, 8425, 32000, 12500, 1300, 2175]),
    '2026-08': (359550, 794200, 82500, 25000,
        [125000, 60196, 12095, 11738, 32823, 6500, 1599, 42000, 0, 11199, 8425, 32000, 12500, 1300, 2175]),
    '2026-09': (428752, 750000, 82500, 25000,
        [125000, 60387, 12095, 11749, 32823, 6500, 1599, 42000, 0, 80199, 8425, 32000, 12500, 1300, 2175]),
    '2026-10': (379796, 750000, 82500, 25000,
        [125000, 67920, 12095, 11760, 32823, 6500, 1599, 42000, 10700, 12999, 8425, 32000, 12500, 1300, 2175]),
    '2026-11': (360156, 771300, 82500, 25000,
        [125000, 60769, 12095, 11771, 32823, 6500, 1599, 42000, 0, 11199, 8425, 32000, 12500, 1300, 2175]),
    '2026-12': (360358, 750000, 82500, 25000,
        [125000, 60960, 12095, 11782, 32823, 6500, 1599, 42000, 0, 11199, 8425, 32000, 12500, 1300, 2175]),
}
EXPECTED_ANNUAL = (4424295, 9126350, 990000, 300000)
EXPECTED_ANNUAL_CATEGORIES = [1500000, 726256, 145790, 140658, 393876, 78000, 17988, 504000, 28500, 208676, 103351, 384000, 150000, 17100, 26100]


def parse_pdf(path):
    xml = subprocess.check_output(['pdftotext', '-bbox', str(path), '-'], text=True)
    root = ET.fromstring(xml)
    rows = []
    page_texts = []
    ns = {'x': 'http://www.w3.org/1999/xhtml'}
    for page_number, page in enumerate(root.findall('.//x:page', ns), 1):
        lines = defaultdict(list)
        words = page.findall('x:word', ns)
        page_texts.append(' '.join(w.text or '' for w in words))
        for word in words:
            lines[round(float(word.attrib['yMin']), 1)].append(word)
        for y, words in sorted(lines.items()):
            words.sort(key=lambda w: float(w.attrib['xMin']))
            if not re.fullmatch(r'2026-\d{2}-\d{2}', words[0].text or ''):
                continue
            money = [w for w in words if float(w.attrib['xMin']) > 600]
            if len(money) != 1:
                raise AssertionError(f'{path}: expected one amount in row at {y}')
            right = float(money[0].attrib['xMax'])
            if abs(right - 697) < 1:
                sign = -1  # Debit column
            elif abs(right - 760) < 1:
                sign = 1  # Credit column
            else:
                raise AssertionError(f'{path}: amount outside debit/credit columns: {right}')
            desc = [w.text for w in words if 100 < float(w.attrib['xMin']) < 600]
            for y2, continuation in sorted(lines.items()):
                if y < y2 <= y + 12 and min(float(w.attrib['xMin']) for w in continuation) >= 100:
                    desc.extend(w.text for w in sorted(continuation, key=lambda w: float(w.attrib['xMin'])))
            rows.append(dict(date=words[0].text, description=' '.join(desc),
                             signed_amount_cents=sign * int(Decimal(money[0].text.replace(',', '')) * 100),
                             page=page_number))
    return page_texts, rows


class TalunYearTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifest = json.loads((ROOT / 'manifest.json').read_text())
        cls.events = {e['event_id']: e for e in cls.manifest['events']}
        cls.documents = {d['path']: d for d in cls.manifest['documents']}

    def test_regeneration_is_byte_identical_twice_and_matches_committed_files(self):
        with tempfile.TemporaryDirectory(prefix='talun-year-test-') as temp:
            first, second = Path(temp) / 'first', Path(temp) / 'second'
            generated = year.build(first)
            year.build(second)
            same_renderer = generated['raster_renderer'] == self.manifest['raster_renderer']
            expected = set(self.documents) | {'manifest.json'}
            self.assertEqual(expected, {p.name for p in first.iterdir()})
            self.assertEqual(expected, {p.name for p in second.iterdir()})
            for name in sorted(expected):
                with self.subTest(name=name):
                    self.assertEqual((first / name).read_bytes(), (second / name).read_bytes())
                    # Pillow wheels bundle different FreeType/shaping/codec builds.
                    # Every platform must reproduce itself byte for byte. Committed
                    # raster bytes also match when the native renderer matches;
                    # PDF/CSV bytes and accounting semantics match on all platforms.
                    if same_renderer or name.endswith(('.pdf', '.csv')):
                        self.assertEqual((ROOT / name).read_bytes(), (first / name).read_bytes())
                    elif name.endswith(('.png', '.jpg')):
                        with Image.open(first / name) as actual, Image.open(ROOT / name) as committed:
                            self.assertEqual(committed.size, actual.size)
                            self.assertEqual(committed.mode, actual.mode)
            def accounting(manifest):
                result = deepcopy(manifest)
                result.pop('raster_renderer')
                for doc in result['documents']:
                    if doc['format'] in {'png', 'jpg'}:
                        doc.pop('sha256')
                        doc.pop('size_bytes')
                return result
            self.assertEqual(accounting(self.manifest), accounting(generated))

    def test_complete_inventory_and_all_account_legs_have_posted_evidence(self):
        manifest = self.manifest
        self.assertEqual('talun_year_v1', manifest['schema_version'])
        self.assertEqual(79, manifest['document_count'])
        self.assertEqual(manifest['document_count'], len(self.documents))
        self.assertEqual(531, len(self.events))
        self.assertEqual(len(self.events), len(manifest['events']))
        self.assertEqual(set(self.documents) | {'README.md', 'manifest.json'}, {p.name for p in ROOT.iterdir() if p.name != '.DS_Store'})
        self.assertLess(sum(d['size_bytes'] for d in self.documents.values()), 6_000_000)
        account_keys = {a['account_key'] for a in manifest['accounts']}
        self.assertEqual({'checking', 'bog', 'savings', 'apple', 'card'}, account_keys)
        for name, doc in self.documents.items():
            with self.subTest(document=name):
                path = ROOT / name
                self.assertTrue(doc['synthetic'])
                self.assertEqual(doc['sha256'], hashlib.sha256(path.read_bytes()).hexdigest())
                self.assertEqual(doc['size_bytes'], path.stat().st_size)
                self.assertLessEqual(set(doc['account_keys']), account_keys)
                self.assertLessEqual(doc['period']['start_on'], doc['period']['end_on'])
                if doc['format'] in {'png', 'jpg'}:
                    with Image.open(path) as image:
                        image.verify()
        # Every account is covered in every month, including savings and image-only months.
        covered = {(line['account_key'], line['date'][:7])
                   for d in self.documents.values() for line in d['lines'] if line['status'] == 'posted'}
        self.assertEqual({(a, f'2026-{m:02}') for a in account_keys for m in range(1, 13)}, covered)
        for event in self.events.values():
            for leg in event['account_legs']:
                refs = [r for r in event['representations'] if r['leg_id'] == leg['leg_id'] and r['status'] == 'posted']
                self.assertTrue(refs, leg['leg_id'])

    def test_every_activity_line_maps_to_exactly_one_event_and_leg_bidirectionally(self):
        seen_lines = set()
        references = Counter()
        for event in self.events.values():
            self.assertIsInstance(event['signed_amount_cents'], int)
            self.assertEqual(event['signed_amount_cents'], event['account_legs'][0]['signed_amount_cents'])
            for ref in event['representations']:
                references[(ref['document_path'], ref['line_id'], event['event_id'], ref['leg_id'], ref['status'])] += 1
        observed = Counter()
        for name, doc in self.documents.items():
            locators = set()
            for line in doc['lines']:
                self.assertNotIn(line['line_id'], seen_lines)
                seen_lines.add(line['line_id'])
                locator = json.dumps(line['locator'], sort_keys=True)
                self.assertNotIn(locator, locators, name)
                locators.add(locator)
                event = self.events[line['event_id']]
                legs = [leg for leg in event['account_legs'] if leg['leg_id'] == line['leg_id']]
                self.assertEqual(1, len(legs))
                self.assertEqual(legs[0]['account_key'], line['account_key'])
                self.assertIn(line['account_key'], doc['account_keys'])
                self.assertEqual(legs[0]['signed_amount_cents'], line['signed_amount_cents'])
                self.assertLessEqual(doc['period']['start_on'], line['date'])
                self.assertLessEqual(line['date'], doc['period']['end_on'])
                observed[(name, line['line_id'], event['event_id'], line['leg_id'], line['status'])] += 1
        self.assertEqual(references, observed)
        self.assertEqual({1}, set(observed.values()))

    def test_monthly_totals_from_economic_events_not_source_copies(self):
        spend_kinds = {'purchase', 'fee', 'interest', 'cash_withdrawal', 'support_to_family', 'refund'}
        allowed_kinds = spend_kinds | {'income', 'transfer_own_accounts', 'card_payment'}
        self.assertEqual({f'2026-{m:02}' for m in range(1, 13)}, set(self.manifest['expected_months']))
        for month, expected in self.manifest['expected_months'].items():
            events = [e for e in self.events.values() if e['date'][:7] == month]
            totals = dict.fromkeys(self.manifest['categories'], 0)
            income = transfer = payment = spending = 0
            transfer_count = 0
            for e in events:
                cents = e['signed_amount_cents']
                kind = e['event_kind']
                self.assertIn(kind, allowed_kinds)
                if kind in spend_kinds:
                    self.assertIn(e['category'], totals)
                    self.assertGreater(cents, 0) if kind == 'refund' else self.assertLess(cents, 0)
                    spending -= cents
                    self.assertEqual(-cents, sum(a['spending_cents'] for a in e['category_allocations']))
                    for allocation in e['category_allocations']:
                        totals[allocation['category']] += allocation['spending_cents']
                else:
                    self.assertEqual([], e['category_allocations'])
                    self.assertIsNone(e['category'])
                    if kind == 'income':
                        self.assertGreater(cents, 0)
                        income += cents
                    else:
                        self.assertLess(cents, 0)
                        self.assertEqual(2, len(e['account_legs']))
                        self.assertEqual(0, sum(leg['signed_amount_cents'] for leg in e['account_legs']))
                        self.assertEqual(2, len({leg['account_key'] for leg in e['account_legs']}))
                        if kind == 'card_payment':
                            payment -= cents
                        else:
                            transfer -= cents
                            transfer_count += 1
            with self.subTest(month=month):
                self.assertEqual(totals, expected['spending_by_category_cents'])
                self.assertEqual(spending, sum(totals.values()))
                self.assertEqual(spending, expected['total_spending_cents'])
                self.assertEqual(income, expected['income_cents'])
                self.assertEqual(transfer, expected['transfers_cents'])
                self.assertEqual(transfer_count, expected['transfer_count'])
                self.assertEqual(payment, expected['card_payments_cents'])
                self.assertEqual(len(events), expected['event_count'])
                self.assertEqual(82500, transfer)  # 200 savings + 500 BOG + 100 top-up + 25 return
                self.assertEqual(25000, payment)
                self.assertEqual(32000, totals['Cash'])  # ATM 100 + branch 200 + store cash back 20

    def test_printed_statement_totals_and_rows_reconcile_with_continuous_balances(self):
        # Read actual PDF text rather than trusting the generator's sidecar totals.
        balances = {a['account_key']: a['opening_balance_cents'] for a in self.manifest['accounts']}
        basis = {a['account_key']: a['account_basis'] for a in self.manifest['accounts']}
        for m in range(1, 13):
            month = f'2026-{m:02}'
            for account in balances:
                amounts = [leg['signed_amount_cents'] for e in self.events.values() if e['date'][:7] == month
                           for leg in e['account_legs'] if leg['account_key'] == account]
                credits = sum(c for c in amounts if c > 0)
                debits = -sum(c for c in amounts if c < 0)
                opening = balances[account]
                closing = opening + (credits - debits) * (-1 if basis[account] == 'liability' else 1)
                balances[account] = closing
                name = f'{account}-{month}.pdf'
                if name not in self.documents:
                    self.assertEqual('bog', account)
                    self.assertIn(m, {2, 5, 7, 8, 9, 11})
                    continue
                doc = self.documents[name]
                expected_totals = dict(opening_balance_cents=opening, closing_balance_cents=closing,
                                       printed_credit_cents=credits, printed_debit_cents=debits)
                self.assertEqual(expected_totals, doc['printed_totals_cents'], name)
                pages, parsed_rows = parse_pdf(ROOT / name)
                self.assertIn('Synthetic test document', ' '.join(pages))
                labels = [('Beginning balance', opening), ('Ending balance', closing),
                          ('Posted credits', credits), ('Posted debits', debits)]
                for page in pages:
                    for label, value in labels:
                        printed = re.search(re.escape(label) + r': \$([\d,]+\.\d{2})', page)
                        self.assertIsNotNone(printed, name)
                        self.assertEqual(value, int(Decimal(printed.group(1).replace(',', '')) * 100))
                self.assertEqual(len(doc['lines']), len(parsed_rows), name)
                page_rows = Counter()
                for line, parsed in zip(doc['lines'], parsed_rows):
                    page_rows[parsed['page']] += 1
                    self.assertEqual(dict(page=parsed['page'], row=page_rows[parsed['page']]), line['locator'])
                    self.assertEqual(line['date'], parsed['date'], name)
                    self.assertEqual(line['description'], parsed['description'], name)
                    self.assertEqual(line['signed_amount_cents'], parsed['signed_amount_cents'], name)
                self.assertEqual(credits, sum(max(r['signed_amount_cents'], 0) for r in parsed_rows))
                self.assertEqual(debits, sum(max(-r['signed_amount_cents'], 0) for r in parsed_rows))

    def test_csv_dates_signs_categories_and_real_triple_format_overlap(self):
        name = 'all-accounts-2026-01-to-06.csv'
        doc = self.documents[name]
        with (ROOT / name).open(newline='') as stream:
            rows = list(csv.reader(stream))
        self.assertEqual(['Date', 'Account', 'Description', 'Amount', 'Category', 'Status'], rows[0])
        self.assertIn('Synthetic test document', rows[-1][0])
        self.assertEqual(len(doc['lines']) + 2, len(rows))
        shifts = set()
        from datetime import date
        for line, printed in zip(doc['lines'], rows[1:-1]):
            event = self.events[line['event_id']]
            self.assertEqual(line['date'], printed[0])
            self.assertTrue(printed[1].endswith(line['account_key']))
            self.assertEqual(line['description'], printed[2])
            self.assertEqual(line['signed_amount_cents'], int(Decimal(printed[3]) * 100))
            self.assertEqual(line['source_category'], printed[4])
            self.assertEqual('Posted', printed[5])
            shifts.add(abs((date.fromisoformat(line['date']) - date.fromisoformat(event['date'])).days))
        self.assertEqual({0, 1, 2, 3}, shifts)
        triple = self.events['talun-2026-03-bog-market-3']
        formats = {self.documents[r['document_path']]['format'] for r in triple['representations']}
        self.assertEqual({'pdf', 'png', 'csv'}, formats)
        for m in {7, 8, 9, 11}:
            evidence = [d for d in self.documents.values() if d['account_keys'] == ['bog'] and d['period']['start_on'] == f'2026-{m:02}-01']
            self.assertEqual(3, len(evidence))
            self.assertEqual({'png'}, {d['format'] for d in evidence})

    def test_duplicate_groups_exclude_counterpart_legs_and_pending(self):
        total = pending = 0
        for month, expected in self.manifest['expected_months'].items():
            groups = {}
            for e in self.events.values():
                if e['date'][:7] != month:
                    continue
                for leg in e['account_legs']:
                    line_ids = []
                    for ref in e['representations']:
                        if ref['leg_id'] != leg['leg_id']:
                            continue
                        if ref['status'] == 'pending':
                            pending += 1
                            continue
                        self.assertEqual(self.documents[ref['document_path']]['kind'], ref['source_kind'])
                        if ref['source_kind'] == 'receipt':
                            continue
                        line_ids.append(ref['line_id'])
                    if len(line_ids) > 1:
                        groups[leg['leg_id']] = (e['event_id'], set(line_ids), len(line_ids) - 1)
            actual = {g['leg_id']: (g['event_id'], set(g['line_ids']), g['duplicate_count']) for g in expected['duplicate_groups']}
            self.assertEqual(groups, actual)
            for group in expected['duplicate_groups']:
                self.assertEqual(group['line_ids'], [r['line_id'] for r in group['copies']])
                for ref in group['copies']:
                    self.assertNotEqual('receipt', ref['source_kind'])
                    self.assertEqual(self.documents[ref['document_path']]['kind'], ref['source_kind'])
            receipt_refs = [dict(event_id=e['event_id'], **ref) for e in self.events.values()
                            if e['date'][:7] == month for ref in e['representations']
                            if ref['source_kind'] == 'receipt']
            self.assertEqual(receipt_refs, expected['receipt_matches'])
            self.assertEqual(1 if month in {'2026-03', '2026-06', '2026-10'} else 0,
                             expected['receipt_match_count'])
            count = sum(values[2] for values in groups.values())
            self.assertEqual(count, expected['true_duplicate_count'])
            total += count
        self.assertEqual(333, total)
        self.assertEqual(7, pending)
        for e in self.events.values():
            for ref in e['representations']:
                if ref['status'] == 'pending':
                    doc = self.documents[ref['document_path']]
                    row = next(r for r in doc['lines'] if r['line_id'] == ref['line_id'])
                    from datetime import date
                    self.assertEqual(1, (date.fromisoformat(e['date']) - date.fromisoformat(row['date'])).days)
                    self.assertLessEqual(max(r['date'] for r in doc['lines'] if r['status'] == 'posted'), row['date'])
                    self.assertTrue(any(r['status'] == 'posted' and r['leg_id'] == ref['leg_id'] for r in e['representations']))

    def test_account_and_descriptor_identifiers_use_invented_values(self):
        self.assertEqual({'checking': '****4410', 'bog': '****6824', 'savings': '****8642',
                          'apple': '****9056', 'card': '****6074'},
                         {a['account_key']: a['masked_identifier'] for a in self.manifest['accounts']})
        identifiers = set()
        for doc in self.documents.values():
            for line in doc['lines']:
                identifiers.update(re.findall(r'(?:S\*····\d+|\*{4}\d+|[Cc]ard \d+|650-····\d+)',
                                              line['description']))
        self.assertEqual({'****4410', '****6824', '****8642', '****9056', '****6074',
                          'Card 7302', 'card 7302', 'S*····7788', 'S*····8899', '650-····1111'}, identifiers)
        for doc in self.documents.values():
            if doc['kind'] == 'receipt':
                self.assertEqual({'tender': 'Debit card 7302'}, doc['lines'][0]['locator'])

    def test_reviewed_monthly_and_annual_constants(self):
        self.assertEqual(EXPECTED_CATEGORIES, self.manifest['categories'])
        actual_annual = [0, 0, 0, 0]
        actual_categories = [0] * len(EXPECTED_CATEGORIES)
        for month, (spending, income, transfers, payments, categories) in EXPECTED_MONTHS.items():
            expected = self.manifest['expected_months'][month]
            actual = tuple(expected[k] for k in ('total_spending_cents', 'income_cents',
                                                 'transfers_cents', 'card_payments_cents'))
            self.assertEqual((spending, income, transfers, payments), actual, month)
            self.assertEqual(dict(zip(EXPECTED_CATEGORIES, categories)), expected['spending_by_category_cents'], month)
            actual_annual = [a + b for a, b in zip(actual_annual, actual)]
            actual_categories = [a + b for a, b in zip(actual_categories, (expected['spending_by_category_cents'][c] for c in EXPECTED_CATEGORIES))]
        self.assertEqual(EXPECTED_ANNUAL, tuple(actual_annual))
        self.assertEqual(EXPECTED_ANNUAL_CATEGORIES, actual_categories)
        self.assertEqual(48, sum(v['transfer_count'] for v in self.manifest['expected_months'].values()))
        self.assertEqual(12, sum(e['event_kind'] == 'card_payment' for e in self.events.values()))

    def test_monthly_money_from_pdf_and_screenshot_source_rows_by_description(self):
        # Do not read event kinds, category allocations, account legs or CSV labels.
        # Screenshot lines are the displayed source-row sidecar. Select captures by
        # their known crop positions; never collapse identical purchase tuples.
        source_rows = defaultdict(list)
        for name, doc in self.documents.items():
            if doc['format'] == 'pdf':
                _, rows = parse_pdf(ROOT / name)
                source_rows[doc['period']['start_on'][:7]].extend(rows)
        for month in (2, 5, 7, 8, 9, 11):
            key = f'2026-{month:02}'
            captures = [self.documents[f'bog-{key}-phone-{i}.png']['lines'] for i in (1, 2, 3)]
            # Captures overlap by two rows; capture 2 supplies the posted version
            # of capture 1's pending row. March uses its complete PDF instead.
            rows = captures[0][:-1] + captures[1][1:] + captures[2][2:]
            self.assertTrue(all(r['status'] == 'posted' for r in rows))
            source_rows[key].extend(rows)
        for month, rows in source_rows.items():
            spending = income = 0
            for row in rows:
                self.assertEqual(month, row['date'][:7])
                desc = row['description'].lower()
                cents = row['signed_amount_cents']
                if 'payroll' in desc or 'weekend repairs' in desc:
                    income += cents
                elif any(word in desc for word in ('payment received', 'payment to mainland visa', 'transfer', 'top-up')):
                    continue
                else:
                    spending -= cents  # includes refunds as negative spending
            self.assertEqual(self.manifest['expected_months'][month]['total_spending_cents'], spending, month)
            self.assertEqual(self.manifest['expected_months'][month]['income_cents'], income, month)
        self.assertEqual(set(EXPECTED_MONTHS), set(source_rows))

    def test_identical_coffees_are_two_legitimate_purchases(self):
        twins = [e for e in self.events.values() if e.get('distinct_purchase_group') == 'january-coffee-twins']
        self.assertEqual(2, len(twins))
        self.assertEqual(2, len({e['event_id'] for e in twins}))
        self.assertEqual({'2026-01-21'}, {e['date'] for e in twins})
        self.assertEqual({-650}, {e['signed_amount_cents'] for e in twins})
        self.assertEqual({'Apple Cash purchase - Tasi Demo Coffee GU'},
                         {e['account_legs'][0]['description'] for e in twins})
        _, rows = parse_pdf(ROOT / 'apple-2026-01.pdf')
        self.assertEqual(2, sum(r['date'] == '2026-01-21' and r['signed_amount_cents'] == -650
                               and r['description'] == 'Apple Cash purchase - Tasi Demo Coffee GU' for r in rows))
        groups = self.manifest['expected_months']['2026-01']['duplicate_groups']
        self.assertEqual(2, sum(g['event_id'] in {e['event_id'] for e in twins} for g in groups))

    def test_receipts_and_known_regression_scenarios(self):
        receipts = [d for d in self.documents.values() if d['kind'] == 'receipt']
        self.assertEqual(3, len(receipts))
        for doc in receipts:
            receipt = doc['receipt']
            event = self.events[receipt['matching_bank_event_id']]
            self.assertEqual(receipt['subtotal_cents'], sum(i['amount_cents'] for i in receipt['items']))
            self.assertEqual(receipt['total_cents'], receipt['subtotal_cents'] - receipt['discount_cents'] + receipt['tax_cents'])
            self.assertEqual(receipt['total_cents'], receipt['new_money_cents'] + receipt['voucher_cents'])
            self.assertEqual(receipt['new_money_cents'], -event['signed_amount_cents'])
            self.assertEqual(receipt['expected_category_allocations'], event['category_allocations'])
            self.assertTrue(any(r['document_path'] == f'checking-{event["date"][:7]}.pdf' for r in event['representations']))
        voucher = self.events['talun-2026-06-voucher-receipt']
        self.assertEqual(-3488, voucher['signed_amount_cents'])
        mixed = self.events['talun-2026-10-mixed-receipt']
        self.assertEqual({'Groceries': 7342, 'Household': 1800, 'Medical': 1200},
                         {a['category']: a['spending_cents'] for a in mixed['category_allocations']})
        refund = self.events['talun-2026-03-linked-refund']
        original = self.events[refund['refund_of_event_id']]
        self.assertEqual('purchase', original['event_kind'])
        self.assertEqual(refund['merchant'], original['merchant'])
        self.assertLessEqual(refund['signed_amount_cents'], -original['signed_amount_cents'])
        self.assertLess(original['date'], refund['date'])
        self.assertNotIn('talun-2026-04-power', self.events)
        self.assertEqual('2026-04', self.events['talun-2026-05-power-arrears']['service_month'])
        self.assertEqual('fee', self.events['talun-2026-05-power-late-fee']['event_kind'])
        self.assertEqual(1, sum(e['signed_amount_cents'] == -69000 for e in self.events.values()))
        self.assertEqual('one_time', self.events['talun-2026-09-one-off-repair']['cadence'])
        self.assertEqual(5, sum(e.get('cadence') == 'irregular' for e in self.events.values()))
        self.assertIn('Cash back 20.00', self.events['talun-2026-01-cashback']['account_legs'][0]['description'])
        for m in range(1, 13):
            stream = self.events[f'talun-2026-{m:02}-streaming']
            self.assertEqual(-1399 if m <= 6 else -1599, stream['signed_amount_cents'])
            self.assertEqual(5 if m == 1 else 4, sum(e['date'][5:7] == f'{m:02}' and e['event_kind'] == 'purchase'
                                  and e['account_legs'][0]['account_key'] == 'apple' for e in self.events.values()))


if __name__ == '__main__':
    unittest.main()
