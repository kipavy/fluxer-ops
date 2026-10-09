"""webhook_post.py: splitting under the limit, fences. stdlib only."""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import webhook_post as w  # noqa: E402


def lines(n, width=60):
    return "\n".join(f"- line {i} " + "x" * width for i in range(n))


class Chunk(unittest.TestCase):
    def test_short_text_is_one_message(self):
        self.assertEqual(w.chunk("a\nb\n"), ["a\nb"])

    def test_every_message_fits(self):
        for c in w.chunk(lines(200)):
            self.assertLessEqual(len(c), w.LIMIT)

    def test_a_typical_post_is_one_message(self):
        self.assertEqual(len(w.chunk(lines(40))), 1)

    def test_fence_closed_at_the_cut_and_reopened(self):
        chunks = w.chunk("```\n" + lines(80) + "\n```")
        self.assertGreater(len(chunks), 1)
        for c in chunks:
            self.assertEqual(c.count("```") % 2, 0, c[:30])

    def test_too_long_is_cut_with_a_pointer(self):
        chunks = w.chunk(lines(400))
        self.assertEqual(len(chunks), w.MAX_MESSAGES)
        self.assertIn("fluxer changelog", chunks[-1])

    def test_blank_text_posts_nothing(self):
        self.assertEqual(w.chunk("\n\n"), [])


if __name__ == "__main__":
    unittest.main()
