"""Offline checks of tools/gen_content.py: parsers and scripture fallbacks.

Usage, from the repository root:
    python3 -I spec/gen_content_test.py

The fixtures are made-up text in the markup of each source; nothing is
downloaded.
"""

import contextlib
import importlib.util
import io
import os
import sys
import unittest

sys.dont_write_bytecode = True  # keep tools/ free of __pycache__
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
_spec = importlib.util.spec_from_file_location("gen_content", os.path.join(ROOT, "tools", "gen_content.py"))
gen = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gen)

# The markup of Project Gutenberg eBook #62383 (HTML edition): one paragraph
# per verse, the chapter number in place of verse 1, footnote and
# alternative-reading anchors, a page number in the middle of a verse.
ALMEIDA_FIXTURE = """
<h2 id="LUC">EVANGELHO</h2>
<p class="center">Mat. <a href="#Mat1-1" class="pginternal">1.1</a>.</p>
<p id="Luc2-1"><span class="first">2</span> Alpha <a id="FNanchor_1"></a><a class="fnanchor
pginternal" href="#Footnote_1">[1]</a> beta <i>gamma</i> ,</p>
<p><span class="pagenum"><a id="Page_9">[9]</a></span></p>
<p id="Luc2-2">2 Delta<a id="ENanchor_2"></a><a class="fnanchor pginternal" href="#Endnote_2">[AEY]</a>
epsilon <span class="pagenum"><a id="Page_10">[10]</a></span> zeta
<span class="smcap">Eta</span>.</p>
<p id="IJoao1-1"><span class="first">1</span> Not a gospel verse.</p>
<p id="Act3-12">12 Theta&nbsp;iota;</p>
"""


class AlmeidaParserTest(unittest.TestCase):
    def test_reads_each_verse_without_numbers_notes_or_page_marks(self):
        books = gen.parse_almeida(ALMEIDA_FIXTURE)
        self.assertEqual(books["Lc"], {(2, 1): "Alpha beta gamma,", (2, 2): "Delta epsilon zeta Eta."})
        self.assertEqual(books["Hch"], {(3, 12): "Theta iota;"})

    def test_ignores_books_that_share_a_suffix_with_a_gospel(self):
        books = gen.parse_almeida(ALMEIDA_FIXTURE)
        self.assertEqual(books["Jn"], {})
        self.assertEqual(sorted(books), sorted(gen.ALMEIDA_BOOKS))


class DroppedScriptureTest(unittest.TestCase):
    VERSES = {(1, 30): "Alpha beta.", (1, 31): "Gamma delta."}

    def lookup(self, book, chapter):
        return self.VERSES, "https://example.org/bible"

    def test_builds_the_fragment_when_every_verse_is_there(self):
        fragment = gen.translated_fragment([("Lc", 1, 30, 31)], (self.lookup, "Test"), "pt", "gozosos 1")
        self.assertEqual(fragment["text"], "Alpha beta. Gamma delta.")
        self.assertEqual(fragment["citation"], "Lc 1,30-31")

    def test_reports_each_dropped_fragment_with_the_missing_verse(self):
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            first = gen.translated_fragment([("Lc", 1, 30, 32)], (self.lookup, "Test"), "pt", "gozosos 1")
            second = gen.translated_fragment([("Lc", 2, 1, 1)], (self.lookup, "Test"), "pt", "gozosos 3")
        self.assertIsNone(first)
        self.assertIsNone(second)
        lines = err.getvalue().splitlines()
        self.assertEqual(len(lines), 2, err.getvalue())
        self.assertIn("pt gozosos 1", lines[0])
        self.assertIn("Lc 1,32", lines[0])
        self.assertIn("pt gozosos 3", lines[1])
        self.assertIn("Lc 2,1", lines[1])

    def test_spanish_fails_on_a_missing_verse(self):
        with self.assertRaises(gen.MissingVerse) as raised:
            gen.build_fragment([("Lc", 1, 31, 33)], self.lookup, "Test", "es")
        self.assertEqual(str(raised.exception), "Lc 1, 32")


if __name__ == "__main__":
    unittest.main()
