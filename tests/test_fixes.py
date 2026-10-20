"""Unit tests for the correction rules."""

import unittest

from applevision_ocr.fixes import fix_text


class FixTextTest(unittest.TestCase):
    def test_common_word_errors(self):
        self.assertEqual(fix_text("开婚走向主流"), "开始走向主流")
        self.assertEqual(fix_text("竟争力"), "竞争力")
        self.assertEqual(fix_text("债劵市场"), "债券市场")
        self.assertEqual(fix_text("欢盟与欢洲"), "欧盟与欧洲")

    def test_de_is_restored(self):
        self.assertEqual(fix_text("下跌钓阴影"), "下跌的阴影")
        self.assertEqual(fix_text("经济”钓开端"), "经济”的开端")
        self.assertEqual(fix_text("老登股”哟增长逻辑"), "老登股”的增长逻辑")

    def test_fishing_is_preserved(self):
        # 钓 must only become 的 when it is not part of 钓鱼/垂钓.
        self.assertEqual(fix_text("他在钓鱼"), "他在钓鱼")
        self.assertEqual(fix_text("垂钓的人"), "垂钓的人")

    def test_ru_confusion(self):
        self.assertEqual(fix_text("陷人绝望"), "陷入绝望")
        self.assertEqual(fix_text("买人机会"), "买入机会")
        # 送人 is a real word and must survive.
        self.assertEqual(fix_text("把书送人"), "把书送人")

    def test_double_de_collapsed(self):
        self.assertEqual(fix_text("服务业的基本的的形态"), "服务业的基本的形态")

    def test_ai_restored_only_between_cjk(self):
        self.assertEqual(fix_text("“AT”叙事"), "“AI”叙事")
        self.assertEqual(fix_text("AT&T"), "AT&T")

    def test_disabled(self):
        self.assertEqual(fix_text("开婚", enabled=False), "开婚")


if __name__ == "__main__":
    unittest.main()
