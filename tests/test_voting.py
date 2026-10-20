"""Unit tests for multi-pass character voting."""

import unittest

from vision_ocr.voting import vote, vote_line


class VoteLineTest(unittest.TestCase):
    def test_identical_passes_untouched(self):
        line = "这是一个测试句子"
        self.assertEqual(vote_line([line, line, line]), line)

    def test_majority_fixes_single_error(self):
        passes = ["这是一个测试句子", "这是一个测试旬子", "这是一个测试句子"]
        self.assertEqual(vote_line(passes), "这是一个测试句子")

    def test_de_is_kept_when_only_one_pass_saw_it(self):
        # 的 is dropped far more often than it is invented.
        passes = ["模糊却强烈时代征兆", "模糊却强烈的时代征兆", "模糊却强烈时代征兆"]
        self.assertEqual(vote_line(passes), "模糊却强烈的时代征兆")

    def test_no_duplicate_insertion(self):
        # Regression: aligning on a rebuilt string used to insert 的 twice.
        passes = [
            "经重塑了制造业与服务业基本形态",
            "经重塑了制造业与服务业的基本形态",
            "经重塑了制造业与服务业的基本形态",
        ]
        self.assertEqual(vote_line(passes), "经重塑了制造业与服务业的基本形态")

    def test_confusion_chars_resolve_to_de(self):
        passes = ["经济”钓开端", "经济”前开端", "经济”的开端"]
        self.assertEqual(vote_line(passes), "经济”的开端")

    def test_de_bias_only_affects_ties(self):
        # With the bias off, a tie between 的 and a confusion char keeps the
        # literal reading; gaps still never delete a character.
        tied = ["经济”钓开端", "经济”的开端", "经济”前开端"]
        self.assertEqual(vote_line(tied, de_bias=True), "经济”的开端")
        self.assertNotEqual(vote_line(tied, de_bias=False), "经济”的开端")


class VotePagesTest(unittest.TestCase):
    def _line(self, y, text):
        return {"p": 1, "x": 0.15, "y": y, "w": 0.7, "h": 0.02, "t": text}

    def test_lines_matched_by_position(self):
        a = {1: [self._line(0.2, "第一行文字"), self._line(0.25, "第二行文字")]}
        b = {1: [self._line(0.2, "第一行文宇"), self._line(0.25, "第二行文字")]}
        c = {1: [self._line(0.2, "第一行文字"), self._line(0.25, "第二行文字")]}
        result = vote([a, b, c])
        self.assertEqual([l["t"] for l in result[1]], ["第一行文字", "第二行文字"])

    def test_falls_back_when_vote_loses_text(self):
        # A pass that merged lines must not be allowed to truncate the page.
        full = {1: [self._line(0.2, "完整的一整行文字内容"), self._line(0.25, "第二行文字")]}
        broken = {1: [self._line(0.2, "完整")]}
        result = vote([broken, full, full])
        total = sum(len(l["t"]) for l in result[1])
        self.assertEqual(total, 15)


if __name__ == "__main__":
    unittest.main()
