"""Exercise the review generator without host fonts or changing committed fixtures."""
import json
from pathlib import Path
import runpy
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

from PIL import ImageFont


class ReviewGeneratorTest(unittest.TestCase):
    def test_generates_scanned_fixture_without_platform_fonts(self):
        source = Path(__file__).resolve().parents[1]
        original_font = ImageFont.truetype

        def portable_font(font, *args, **kwargs):
            self.assertNotIn('/System/Library/', str(font))
            return original_font(font, *args, **kwargs)

        with tempfile.TemporaryDirectory(prefix='review-generator-') as temporary:
            root = Path(temporary)
            scripts = root / 'scripts/synthetic-documents'
            scripts.mkdir(parents=True)
            output = root / 'api/test/fixtures/files/documents/v2'
            output.mkdir(parents=True)
            for name in ('generate.py', 'generate_review_v1.py'):
                shutil.copyfile(source / name, scripts / name)
            sys.path.insert(0, str(scripts))
            prior = sys.modules.pop('generate', None)
            try:
                with patch.object(ImageFont, 'truetype', side_effect=portable_font):
                    runpy.run_path(str(scripts / 'generate_review_v1.py'), run_name='__main__')
                review = output / 'review-1'
                manifest = json.loads((review / 'manifest.json').read_text())
                self.assertEqual(7, len(manifest['documents']))
                self.assertTrue((review / 'scanned-text-footer.pdf').is_file())
                self.assertEqual(2, json.loads((review / 'scanned-text-footer.pdf.expected.json').read_text())['page_count'])
            finally:
                sys.path.pop(0)
                sys.modules.pop('generate', None)
                if prior is not None:
                    sys.modules['generate'] = prior


if __name__ == '__main__':
    unittest.main()
