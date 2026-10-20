"""Turn positioned OCR lines into readable text.

The engine gives us one record per line with normalised coordinates. That is
enough to recover most of a book's structure without knowing anything about
the specific document:

* running headers/footers repeat across pages, or sit in the top margin
* paragraphs start with an indent, so their left edge is further right
* footnotes use a smaller type size than the body
* tables are pages made mostly of short fragments, which cluster into a grid
* figures have a caption and scattered labels that cannot be linearised
"""

from __future__ import annotations

import re
from collections import Counter
from dataclasses import dataclass

from .fixes import fix_text

FIG_RE = re.compile(r"^\s*(图|Figure|Fig\.?)\s*\d+", re.I)
CAP_RE = re.compile(r"^\s*(表|Table)\s*\d+", re.I)
SOURCE_PREFIX = ("数据来源", "资料来源", "Source")


@dataclass
class LayoutOptions:
    tables: bool = True
    furniture: str = "auto"      # "auto" | "off"
    notes: str = "end"           # "end" | "drop"
    col_gap: float = 0.030
    fix: bool = True


def detect_furniture(pages: dict[int, list[dict]]) -> set[str]:
    """Text that repeats in the margins across pages, digits normalised."""
    if len(pages) < 3:
        return set()
    seen_on: Counter = Counter()
    for lines in pages.values():
        keys = set()
        for line in lines:
            if line["y"] < 0.13 or line["y"] > 0.87:
                key = re.sub(r"\d+", "#", line["t"]).strip()
                if len(key) >= 2:
                    keys.add(key)
        seen_on.update(keys)
    threshold = max(3, int(len(pages) * 0.35))
    return {key for key, count in seen_on.items() if count >= threshold}


def is_furniture(text: str, furniture: set[str], y: float | None = None) -> bool:
    if re.sub(r"\d+", "#", text).strip() in furniture:
        return True
    if re.fullmatch(r"[-–—\s]*\d{1,4}[-–—\s]*", text):
        return True
    if y is None:
        return False
    # Header: top of the page, short, contains a number.
    if y < 0.115 and len(text) <= 32 and (re.search(r"\d", text) or len(text) <= 12):
        return True
    # Footer: bottom of the page, bare page number.
    if y > 0.935 and len(text) <= 8 and re.search(r"\d", text):
        return True
    return False


def split_table(
    lines: list[dict], gap: float, exclude: set[int] | None = None
) -> tuple[list[dict], list[str], list[dict]]:
    """Split a table page into (text before, grid rows, text after)."""
    exclude = exclude or set()
    short_idx = [i for i, line in enumerate(lines) if len(line["t"]) <= 14]
    if len(short_idx) < 6:
        return lines, [], []

    start, end = short_idx[0], short_idx[-1]
    cells = sorted(
        [l for l in lines[start:end + 1] if id(l) not in exclude],
        key=lambda l: l["y"],
    )

    columns: list[list[float]] = []
    for x in sorted(line["x"] for line in cells):
        if not columns or x - columns[-1][-1] > gap:
            columns.append([x])
        else:
            columns[-1].append(x)
    centers = [sum(col) / len(col) for col in columns]

    rows: list[list[dict]] = []
    for line in cells:
        if not rows or line["y"] - rows[-1][0]["y"] > 0.014:
            rows.append([line])
        else:
            rows[-1].append(line)

    matrix: list[list[str]] = []
    for row in rows:
        bucket: dict[int, str] = {}
        for line in row:
            idx = min(range(len(centers)), key=lambda i: abs(centers[i] - line["x"]))
            bucket[idx] = bucket.get(idx, "") + line["t"]
        matrix.append([bucket.get(i, "") for i in range(len(centers))])

    keep = [i for i in range(len(centers)) if any(r[i].strip() for r in matrix)]
    grid: list[str] = []
    for row in matrix:
        line = " | ".join(row[i] for i in keep).strip(" |")
        line = re.sub(r"(\s*\|\s*)+$", "", line).strip()
        if line.strip(" |"):
            grid.append(line)
    return lines[:start], grid, lines[end + 1:]


def layout(pages: dict[int, list[dict]], options: LayoutOptions) -> str:
    """Render pages as text: paragraphs, tables, figure placeholders, notes."""
    furniture = detect_furniture(pages) if options.furniture == "auto" else set()
    out: list[str] = []
    notes: list[tuple[int, str]] = []
    current = ""

    def flush() -> None:
        nonlocal current
        if current.strip():
            out.append(fix_text(current.strip(), options.fix))
        current = ""

    for page_no in sorted(pages):
        lines = pages[page_no]
        if not lines:
            continue

        heights = [l["h"] for l in lines if len(l["t"]) >= 18]
        body_height = sorted(heights)[len(heights) // 2] if heights else 0.02

        raw = [
            l for l in lines
            if not (options.furniture == "auto" and is_furniture(l["t"], furniture, l["y"]))
        ]
        short = sum(1 for l in raw if len(l["t"]) <= 14)
        is_table = len(raw) >= 8 and short / len(raw) > 0.45

        body: list[dict] = []
        for line in raw:
            text = line["t"]
            is_note = (
                not is_table
                and line["h"] < body_height * 0.72
                and line["y"] > 0.60
                and len(text) > 1
            )
            if is_note:
                starts_new = (
                    re.match(r"^\d{1,2}[\s.、,，]", text)
                    or re.match(r"^\d{1,2}[\[［《]", text)
                    or re.match(r"^[A-Z][A-Za-z]+,\s", text)
                )
                if starts_new or not notes:
                    notes.append((page_no, text))
                elif re.search(r"[A-Za-z]$", notes[-1][1]) and re.match(r"^[A-Za-z]", text):
                    notes[-1] = (notes[-1][0], notes[-1][1] + " " + text)
                else:
                    notes[-1] = (notes[-1][0], notes[-1][1] + text)
                continue
            body.append(line)

        if not body:
            continue

        margins = [round(l["x"], 2) for l in body if len(l["t"]) >= 18]
        margin = Counter(margins).most_common(1)[0][0] if margins else 0.15
        indent = margin + 0.022
        candidates = [x for x in margins if x > margin + 0.012]
        if candidates:
            indent = margin + min(0.030, (min(candidates) - margin) * 0.55 + 0.006)

        def feed(segment: list[dict]) -> None:
            nonlocal current
            for line in segment:
                text = line["t"]
                centered = line["x"] >= 0.30 and len(text) <= 26
                if centered:
                    flush()
                    out.append("")
                    out.append(fix_text(text, options.fix))
                    out.append("")
                elif line["x"] >= indent:
                    flush()
                    current = text
                elif not current:
                    current = text
                elif re.search(r"[A-Za-z0-9]$", current) and re.match(r"^[A-Za-z0-9]", text):
                    current += " " + text
                else:
                    current += text

        captions = [l for l in body if FIG_RE.match(l["t"])]
        if captions:
            cap_y = captions[0]["y"]
            items: list[tuple[float, str, str]] = []
            for line in body:
                text = line["t"]
                if line is captions[0] or (abs(line["y"] - cap_y) < 0.022 and line["x"] >= 0.30):
                    continue
                if text.startswith(SOURCE_PREFIX):
                    items.append((line["y"], "source", text))
                elif line["x"] < 0.30 and len(text) >= 15:
                    items.append((line["y"], "body", text))
                elif (
                    line["x"] >= 0.30
                    and 0.30 < line["y"] < cap_y
                    and 4 <= len(text) <= 26
                    and not re.match(r"^[\d\-—–.年月日]+$", text)
                ):
                    items.append((line["y"], "heading", text))
            items.append((cap_y, "caption", captions[0]["t"]))
            items.sort(key=lambda item: item[0])

            for y, kind, text in items:
                if kind == "caption":
                    flush()
                    out += ["", f"〔{fix_text(text, options.fix)}（图形无法用文字还原，见原页）〕", ""]
                elif kind == "heading":
                    flush()
                    out += ["", fix_text(text, options.fix), ""]
                elif kind == "source":
                    flush()
                    out.append(fix_text(text, options.fix))
                else:
                    feed([{"x": 0.16, "y": y, "h": body_height, "t": text}])
            continue

        if is_table and options.tables:
            cap_lines = [
                l for l in body
                if CAP_RE.match(re.sub(r"^(\s*\|)+\s*", "", l["t"]))
            ]
            lead, grid, tail = split_table(body, options.col_gap, {id(x) for x in cap_lines})
            if lead:
                feed(lead)
            flush()
            out.append("")
            if cap_lines:
                caption = " ".join(
                    fix_text(re.sub(r"^(\s*\|)+\s*", "", l["t"]).strip(), options.fix)
                    for l in cap_lines
                )
                while grid and "|" not in grid[0] and len(grid[0]) <= 22:
                    caption += " " + fix_text(grid.pop(0), options.fix)
                out.append(caption)
            out.extend(fix_text(row, options.fix) for row in grid)
            out.append("")
            if tail:
                feed(tail)
            continue

        feed(body)

    flush()
    text = "\n".join(out)
    text = re.sub(r"\n{3,}", "\n\n", text)

    if notes and options.notes == "end":
        block = ["", "", "【注释】"]
        for page_no, note in notes:
            block.append(f"[p{page_no}] {fix_text(note, options.fix)}")
        text += "\n".join(block)
    return text
