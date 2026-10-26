"""Tests for tools/wiki/build_wiki.py (run from the repository root)."""

import os
import re
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "wiki"))
import build_wiki  # noqa: E402  (path set above)


class BuildWikiTest(unittest.TestCase):
    """Builds the wiki from the real README and checks its links."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.pages = build_wiki.build(cls.tmp.name)
        cls.text = {}
        for name in cls.pages:
            with open(os.path.join(cls.tmp.name, name + ".md"), encoding="utf-8") as handle:
                cls.text[name] = handle.read()

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_core_pages_exist(self):
        for name in ("Home", "Walkthrough", "Roadmap-and-Status", "Installation",
                     "Troubleshooting", "_Sidebar", "_Footer"):
            self.assertIn(name, self.pages)

    def test_version_filled_in(self):
        self.assertNotIn("{{", self.text["Home"])
        self.assertIn("v" + build_wiki.version(), self.text["Home"])

    def test_no_relative_file_links_left(self):
        for name, text in self.text.items():
            for target in re.findall(r"\]\(([^)\s]+)\)", text):
                if target.startswith(("http", "#")):
                    continue
                page = target.split("#")[0]
                self.assertIn(page, self.pages, f"{name}: link to {target}")

    def test_linked_repository_files_exist(self):
        for name, text in self.text.items():
            for path in re.findall(r"/main/([^)#\s]+)\)", text):
                self.assertTrue(os.path.exists(path), f"{name}: {path} missing")

    def test_anchors_resolve(self):
        heads = {name: {build_wiki.slug(h) for h in re.findall(r"^#+\s+(.*?)\s*$", text, re.M)}
                 for name, text in self.text.items()}
        for name, text in self.text.items():
            for page, anchor in re.findall(r"\]\(([A-Za-z][\w-]*)?#([^)]+)\)", text):
                page = page or name
                if page in heads:
                    self.assertIn(anchor, heads[page], f"{name}: {page}#{anchor}")


if __name__ == "__main__":
    unittest.main()
