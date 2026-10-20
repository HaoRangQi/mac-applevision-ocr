"""Command line interface."""

from __future__ import annotations

import argparse
import json
import os
import sys

from . import __version__
from .engine import EngineNotFound, group_pages, run
from .layout import LayoutOptions, layout
from .voting import vote

DEFAULT_SCALES = "3.5,4.5,5.6"


def wrap_text(text: str, width: int) -> str:
    """Soft-wrap CJK text at sentence punctuation near the target width."""
    if not width:
        return text
    out: list[str] = []
    for line in text.split("\n"):
        if len(line) <= width:
            out.append(line)
            continue
        buf = ""
        for ch in line:
            buf += ch
            if len(buf) >= width and ch in "，。；：！？、）》”":
                out.append(buf)
                buf = ""
        if buf:
            out.append(buf)
    return "\n".join(out)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="vision-ocr",
        description="macOS 原生 OCR：扫描版 PDF / 图片 → 文本",
        epilog="示例：vision-ocr book.pdf -p 1-20 -o out.txt",
    )
    parser.add_argument("input", nargs="+", help="PDF 或图片路径")
    parser.add_argument("-o", "--out", help="输出文件；多个输入时视为目录")
    parser.add_argument("-p", "--pages", help="页码范围，如 26-40（仅 PDF）")
    parser.add_argument(
        "--mode", choices=["layout", "text", "json"], default="layout",
        help="layout=还原段落表格（默认）；text=逐行；json=带坐标",
    )
    parser.add_argument(
        "--scales", default=DEFAULT_SCALES,
        help=f"投票用的渲染倍率，逗号分隔；只给一个即关闭投票（默认 {DEFAULT_SCALES}）",
    )
    parser.add_argument("--rot", type=float, default=0, help="整页旋转角度，如 -90")
    parser.add_argument("--lang", default="zh-Hans,en-US", help="识别语言，逗号分隔")
    parser.add_argument("--no-vote", action="store_true", help="关闭多路投票（快 3 倍）")
    parser.add_argument("--no-fix", action="store_true", help="关闭中文常见错字修正")
    parser.add_argument("--no-tables", action="store_true", help="不还原表格")
    parser.add_argument(
        "--notes", choices=["end", "drop"], default="end", help="脚注处理方式"
    )
    parser.add_argument(
        "--furniture", choices=["auto", "off"], default="auto",
        help="页眉页脚识别（截图类文档可用 off）",
    )
    parser.add_argument("--col-gap", type=float, default=0.030, help="表格列间距阈值")
    parser.add_argument("--wrap", type=int, default=0, help="按字数折行（0=不折）")
    parser.add_argument("--fast", action="store_true", help="快速模式（精度略降）")
    parser.add_argument("-q", "--quiet", action="store_true", help="不输出进度")
    parser.add_argument("--version", action="version", version=f"vision-ocr {__version__}")
    return parser


def ocr_file(path: str, args: argparse.Namespace) -> str:
    is_pdf = path.lower().endswith(".pdf")
    scales = [float(s) for s in args.scales.split(",") if s.strip()]
    if args.no_vote or not is_pdf:
        scales = scales[:1] or [4.5]

    passes = []
    for i, scale in enumerate(scales):
        if not args.quiet and len(scales) > 1:
            print(f"  识别 pass {i + 1}/{len(scales)} (scale={scale})", file=sys.stderr)
        lines = run(
            path,
            pages=args.pages,
            scale=scale,
            rot=args.rot,
            langs=args.lang,
            fast=args.fast,
        )
        passes.append(group_pages(lines))

    pages = vote(passes) if len(passes) > 1 else passes[0]

    if args.mode == "json":
        text = "\n".join(
            json.dumps(line, ensure_ascii=False)
            for page_no in sorted(pages)
            for line in pages[page_no]
        )
    elif args.mode == "text":
        text = "\n".join(
            line["t"] for page_no in sorted(pages) for line in pages[page_no]
        )
    else:
        options = LayoutOptions(
            tables=not args.no_tables,
            furniture=args.furniture,
            notes=args.notes,
            col_gap=args.col_gap,
            fix=not args.no_fix,
        )
        text = layout(pages, options)

    if args.mode == "text" and not args.no_fix:
        from .fixes import fix_text
        text = "\n".join(fix_text(line, True) for line in text.split("\n"))

    return wrap_text(text, args.wrap)


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    multiple = len(args.input) > 1

    if multiple and args.out and not os.path.isdir(args.out):
        os.makedirs(args.out, exist_ok=True)

    failures = 0
    for path in args.input:
        if not os.path.exists(path):
            print(f"跳过不存在的文件: {path}", file=sys.stderr)
            failures += 1
            continue
        try:
            text = ocr_file(path, args)
        except EngineNotFound as exc:
            print(str(exc), file=sys.stderr)
            return 2
        except RuntimeError as exc:
            print(f"{path}: {exc}", file=sys.stderr)
            failures += 1
            continue

        if args.out:
            if multiple:
                stem = os.path.splitext(os.path.basename(path))[0]
                dest = os.path.join(args.out, stem + ".txt")
            else:
                dest = args.out
        elif multiple:
            dest = os.path.splitext(path)[0] + ".txt"
        else:
            dest = None

        if dest:
            with open(dest, "w", encoding="utf-8") as handle:
                handle.write(text)
            if not args.quiet:
                print(f"→ {dest}  ({len(text)} 字)", file=sys.stderr)
        else:
            print(text)

    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
