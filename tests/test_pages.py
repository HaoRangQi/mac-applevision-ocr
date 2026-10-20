"""Tests for page-spec parsing (--pages)."""

import unittest

from applevision_ocr.pages import (
    PageSpecError,
    format_pages,
    normalise_pages,
    parse_page_spec,
    parse_pages,
)


class ParsePageSpecTest(unittest.TestCase):
    def test_all_and_empty_mean_every_page(self):
        for spec in (None, "", "   ", "all", "ALL"):
            self.assertEqual(parse_page_spec(spec), [])
            self.assertEqual(parse_pages(spec, 10), list(range(1, 11)))

    def test_single_page(self):
        self.assertEqual(parse_page_spec("7"), [(7, 7)])
        self.assertEqual(parse_pages("7", 20), [7])

    def test_range(self):
        self.assertEqual(parse_page_spec("26-40"), [(26, 40)])
        self.assertEqual(parse_pages("26-40", 100), list(range(26, 41)))

    def test_spaces_around_tokens_are_tolerated(self):
        self.assertEqual(parse_pages(" 3 , 7 - 9 ", 20), [3, 7, 8, 9])

    def test_comma_separated_multiple_segments(self):
        # This is the case the old parser dropped on the floor.
        self.assertEqual(
            parse_pages("1-3,5,20-22", 30), [1, 2, 3, 5, 20, 21, 22]
        )

    def test_bare_negative_means_last_n_pages(self):
        self.assertEqual(parse_pages("-10", 30), list(range(21, 31)))
        self.assertEqual(parse_pages("-1", 5), [5])
        self.assertEqual(parse_pages("-5", 5), [1, 2, 3, 4, 5])

    def test_negative_range_endpoint_counts_from_the_end(self):
        self.assertEqual(parse_pages("10--3", 30), list(range(10, 29)))

    def test_reversed_range_is_corrected(self):
        self.assertEqual(parse_pages("9-4", 20), [4, 5, 6, 7, 8, 9])

    def test_out_of_range_pages_are_dropped(self):
        self.assertEqual(parse_pages("5,99,0", 10), [5])
        self.assertEqual(parse_pages("1-999", 10), list(range(1, 11)))

    def test_duplicates_are_merged_and_sorted(self):
        self.assertEqual(parse_pages("3,1-3,2", 20), [1, 2, 3])


class PageSpecErrorsTest(unittest.TestCase):
    def test_nothing_left_after_clamping(self):
        # 999 is beyond the 10-page document, so nothing survives.
        self.assertEqual(parse_pages("999", 10), [])

    def test_bad_syntax_raises(self):
        for spec in ("1-5-9", "abc", "1,,x", "3-", "--", "1.5", "1 - 2x"):
            with self.assertRaises(PageSpecError, msg=spec):
                parse_page_spec(spec)

    def test_empty_middle_segment_is_skipped(self):
        self.assertEqual(parse_pages("1,,2", 5), [1, 2])


class FormatPagesTest(unittest.TestCase):
    def test_compact_roundtrip(self):
        self.assertEqual(format_pages([1, 2, 3, 5, 20, 21]), "1-3,5,20-21")
        self.assertEqual(format_pages([7]), "7")
        self.assertEqual(format_pages([]), "")

    def test_normalise_matches_expected_engine_input(self):
        self.assertEqual(normalise_pages("26-40", 100), "26-40")
        self.assertEqual(normalise_pages("1,3-5,8", 30), "1,3-5,8")
        self.assertEqual(normalise_pages("-3", 30), "28-30")
        self.assertEqual(normalise_pages("all", 4), "1-4")

    def test_normalised_output_reparses_to_the_same_pages(self):
        original = [1, 2, 3, 9, 10, 14]
        total = 20
        again = parse_pages(format_pages(original), total)
        self.assertEqual(again, original)


if __name__ == "__main__":
    unittest.main()
