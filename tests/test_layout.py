"""Unit tests for layout reconstruction."""

import unittest

from applevision_ocr.layout import LayoutOptions, detect_furniture, is_furniture, layout


def line(text, x=0.15, y=0.2, h=0.025, page=1):
    return {"p": page, "x": x, "y": y, "w": 0.7, "h": h, "t": text}


class FurnitureTest(unittest.TestCase):
    def test_repeated_header_detected(self):
        pages = {
            1: [line("001 某本书名", x=0.12, y=0.07, h=0.016)],
            2: [line("002 某本书名", x=0.12, y=0.07, h=0.016)],
            3: [line("003 某本书名", x=0.12, y=0.07, h=0.016)],
        }
        furniture = detect_furniture(pages)
        self.assertTrue(is_furniture("004 某本书名", furniture, 0.07))

    def test_body_text_kept(self):
        pages = {
            1: [line("001 某本书名", x=0.12, y=0.07, h=0.016)],
            2: [line("002 某本书名", x=0.12, y=0.07, h=0.016)],
            3: [line("003 某本书名", x=0.12, y=0.07, h=0.016)],
        }
        furniture = detect_furniture(pages)
        self.assertFalse(is_furniture("这是一行正文", furniture, 0.4))

    def test_page_number_alone_dropped(self):
        self.assertTrue(is_furniture("123", set(), 0.96))


class ParagraphTest(unittest.TestCase):
    def test_indent_starts_new_paragraph(self):
        pages = {
            1: [
                line("第一段的开头，后面接着写", x=0.19, y=0.20),
                line("继续写第一段的内容。", x=0.15, y=0.24),
                line("第二段从这里开始。", x=0.19, y=0.28),
            ]
        }
        text = layout(pages, LayoutOptions(fix=False, furniture="off"))
        self.assertEqual(
            text.split("\n"),
            ["第一段的开头，后面接着写继续写第一段的内容。", "第二段从这里开始。"],
        )

    def test_cross_page_paragraph_joined(self):
        pages = {
            1: [line("这一句话没有说完，", x=0.19, y=0.85, page=1)],
            2: [line("下一页接着说完了。", x=0.15, y=0.17, page=2)],
        }
        text = layout(pages, LayoutOptions(fix=False, furniture="off"))
        self.assertEqual(text, "这一句话没有说完，下一页接着说完了。")


class TableTest(unittest.TestCase):
    def test_grid_reconstructed(self):
        rows = [
            ("代码", 0.14), ("名称", 0.30), ("涨幅", 0.55),
            ("KS11.GI", 0.14), ("韩国综合", 0.30), ("63.76", 0.55),
            ("HSI.HI", 0.14), ("恒生指数", 0.30), ("28.77", 0.55),
            ("000852", 0.14), ("中证1000", 0.30), ("23.99", 0.55),
            ("000300", 0.14), ("沪深300", 0.30), ("16.60", 0.55),
            ("000001", 0.14), ("上证指数", 0.30), ("17.75", 0.55),
        ]
        body = []
        y = 0.20
        for i, (text, x) in enumerate(rows):
            body.append(line(text, x=x, y=y, h=0.018))
            if i % 3 == 2:
                y += 0.03
        text = layout({1: body}, LayoutOptions(fix=False, furniture="off"))
        self.assertIn("KS11.GI | 韩国综合 | 63.76", text)
        self.assertIn("000001 | 上证指数 | 17.75", text)


class FigureTest(unittest.TestCase):
    def test_caption_becomes_placeholder(self):
        pages = {
            1: [
                line("正文第一段说明图表的内容。", x=0.19, y=0.20),
                line("横轴", x=0.20, y=0.45, h=0.012),
                line("图1-1 美元指数走势图", x=0.35, y=0.75, h=0.019),
                line("数据来源：Wind。", x=0.15, y=0.79),
            ]
        }
        text = layout(pages, LayoutOptions(fix=False, furniture="off"))
        self.assertIn("〔图1-1 美元指数走势图", text)
        self.assertNotIn("横轴", text)
        self.assertIn("数据来源：Wind。", text)


class NotesTest(unittest.TestCase):
    def test_small_text_collected(self):
        pages = {
            1: [
                line("这是正文内容，字号正常，写满一整行的长度。", x=0.19, y=0.30, h=0.026),
                line("1 某作者：《某书》，某出版社2020年版。", x=0.15, y=0.92, h=0.015),
            ]
        }
        text = layout(pages, LayoutOptions(fix=False, furniture="off"))
        self.assertIn("【注释】", text)
        self.assertIn("[p1] 1 某作者", text)


if __name__ == "__main__":
    unittest.main()
