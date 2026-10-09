"""changelog_fmt.py: grouping, filtering and caps. stdlib only."""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import changelog_fmt as f  # noqa: E402


class Classify(unittest.TestCase):
    def test_feat_is_new_with_scope(self):
        self.assertEqual(f.classify("feat(threads): publish forums (#3342)"), ("new", "threads: publish forums (#3342)"))

    def test_fix_and_perf_are_fixes(self):
        self.assertEqual(f.classify("fix(app,api): kick reasons (#3334)")[0], "fixes")
        self.assertEqual(f.classify("perf(gateway): faster")[0], "fixes")

    def test_noise_types_hidden(self):
        for s in ("ci(desktop): x", "chore(i18n): refresh catalog references (#3320)", "test(gateway): x",
                  "docs: use British English (#3336)", "refactor: remove dead code (#3337)"):
            self.assertEqual(f.classify(s)[0], "hidden", s)

    def test_desktop_only_scopes_hidden_even_for_feat(self):
        self.assertEqual(f.classify("feat(desktop): prefer the bundled renderer (#3341)")[0], "hidden")
        self.assertEqual(f.classify("fix(desktop,ci): x")[0], "hidden")

    def test_mixed_scope_with_desktop_is_kept(self):
        self.assertEqual(f.classify("fix(app,desktop): x")[0], "fixes")

    def test_heads_up(self):
        self.assertEqual(f.classify("feat(api)!: drop v0 routes")[0], "notable")
        self.assertEqual(f.classify("revert(admin): restore user type toggles (#3306)")[0], "notable")
        self.assertEqual(f.classify("chore(moderation): remove the built-in NCMEC integration (#3332)")[0], "notable")
        self.assertEqual(f.classify("fix: BREAKING config key renamed")[0], "notable")

    def test_a_fix_that_drops_something_is_a_fix(self):
        self.assertEqual(f.classify("fix(ui): drop the switch label tab stop (#3297)")[0], "fixes")

    def test_not_conventional_is_other(self):
        self.assertEqual(f.classify("Merge branch 'x'"), ("other", "Merge branch 'x'"))


class Render(unittest.TestCase):
    def test_groups_in_order_with_counts_and_hidden_tally(self):
        out = f.render(["fix: a", "feat: b", "ci: c", "revert: d"], "https://x/compare/1...2")
        self.assertLess(out.index("À noter (1)"), out.index("Nouveautés (1)"))
        self.assertLess(out.index("Nouveautés (1)"), out.index("Corrections (1)"))
        self.assertIn("_1 commits masqués", out)
        self.assertIn("<https://x/compare/1...2>", out)
        self.assertNotIn("- c", out)

    def test_caps(self):
        out = f.render([f"fix: n{i}" for i in range(40)])
        self.assertIn("Corrections (40)", out)
        self.assertIn("- n24", out)
        self.assertNotIn("- n25", out)
        self.assertIn("et 15 autres", out)

    def test_empty(self):
        self.assertIn("Aucun commit", f.render([]))


if __name__ == "__main__":
    unittest.main()
