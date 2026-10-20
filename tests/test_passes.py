"""Tests for the pass-count → scale mapping (--passes)."""

import unittest
from unittest import mock

from applevision_ocr.cli import DEFAULT_SCALES, main, scales_for_passes


class ScalesForPassesTest(unittest.TestCase):
    def test_no_passes_keeps_the_default_list(self):
        self.assertEqual(scales_for_passes(None, DEFAULT_SCALES), [3.5, 4.5, 5.6])

    def test_one_pass_is_a_single_scale(self):
        self.assertEqual(scales_for_passes(1, DEFAULT_SCALES), [3.5])

    def test_two_passes_take_the_first_two_scales(self):
        self.assertEqual(scales_for_passes(2, DEFAULT_SCALES), [3.5, 4.5])

    def test_three_passes_take_everything(self):
        self.assertEqual(scales_for_passes(3, DEFAULT_SCALES), [3.5, 4.5, 5.6])

    def test_explicit_scales_win_over_passes(self):
        # The user asked for these exact scales; --passes must not override them.
        self.assertEqual(scales_for_passes(1, "2.0,3.0"), [2.0, 3.0])

    def test_empty_scales_falls_back_to_a_single_default(self):
        self.assertEqual(scales_for_passes(None, ""), [4.5])
        self.assertEqual(scales_for_passes(2, ""), [4.5])


class PassesFlagTest(unittest.TestCase):
    """The CLI must actually run one engine pass per requested scale."""

    def _scales_run(self, argv):
        calls = []

        def fake_run(path, **kwargs):
            calls.append(kwargs["scale"])
            return []

        with mock.patch("applevision_ocr.cli.run", side_effect=fake_run), \
             mock.patch("applevision_ocr.cli.group_pages", return_value={}), \
             mock.patch("applevision_ocr.cli.page_count", return_value=1), \
             mock.patch("applevision_ocr.cli.os.path.exists", return_value=True):
            main(argv)
        return calls

    def test_passes_two_runs_two_scales(self):
        self.assertEqual(self._scales_run(["doc.pdf", "--passes", "2"]), [3.5, 4.5])

    def test_passes_one_runs_a_single_scale(self):
        self.assertEqual(self._scales_run(["doc.pdf", "--passes", "1"]), [3.5])

    def test_passes_three_runs_three_scales(self):
        self.assertEqual(
            self._scales_run(["doc.pdf", "--passes", "3"]), [3.5, 4.5, 5.6]
        )

    def test_default_still_runs_three_scales(self):
        self.assertEqual(self._scales_run(["doc.pdf"]), [3.5, 4.5, 5.6])

    def test_images_always_run_a_single_scale(self):
        # The engine only votes for PDFs; a picture is recognised once.
        self.assertEqual(self._scales_run(["shot.png", "--passes", "3"]), [3.5])

    def test_explicit_scales_win_over_passes(self):
        self.assertEqual(
            self._scales_run(["doc.pdf", "--passes", "1", "--scales", "2.0,3.0"]),
            [2.0, 3.0],
        )


if __name__ == "__main__":
    unittest.main()
