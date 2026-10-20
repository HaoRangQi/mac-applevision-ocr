"""Character-level voting across multiple OCR passes.

The same page is rendered at several scales and recognised independently.
Single-character errors are largely independent between passes, so a
positional majority vote removes most of them.

Two details matter:

* Alignment must be rebuilt from the *non-empty* winner of each column.
  Otherwise a character that only some passes saw gets inserted twice.
* 的 is dropped far more often than it is hallucinated, so a column where any
  pass saw 的 keeps it even without a strict majority.
"""

from __future__ import annotations

import difflib
from collections import Counter

from .fixes import DE_CONFUSIONS


def _best_char(column: Counter) -> str:
    """Most likely character for a column, ignoring gaps."""
    filled = [(ch, n) for ch, n in column.items() if ch]
    if not filled:
        return ""
    return max(filled, key=lambda item: item[1])[0]


def merge_columns(columns: list[Counter], other: str) -> list[Counter]:
    """Align an existing column model against another string and merge it."""
    current = "".join(_best_char(c) for c in columns)
    matcher = difflib.SequenceMatcher(None, current, other, autojunk=False)
    merged: list[Counter] = []

    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == "equal":
            for k in range(i2 - i1):
                col = columns[i1 + k].copy()
                col[other[j1 + k]] += 1
                merged.append(col)
        elif tag == "replace":
            for k in range(max(i2 - i1, j2 - j1)):
                col: Counter = Counter()
                if i1 + k < i2:
                    col.update(columns[i1 + k])
                if j1 + k < j2:
                    col[other[j1 + k]] += 1
                merged.append(col)
        elif tag == "delete":
            for k in range(i1, i2):
                col = columns[k].copy()
                col[""] += 1
                merged.append(col)
        else:  # insert
            for k in range(j1, j2):
                col = Counter()
                col[""] += 1
                col[other[k]] += 1
                merged.append(col)
    return merged


def vote_line(strings: list[str], de_bias: bool = True) -> str:
    """Merge several readings of one line into a single string."""
    if not strings:
        return ""
    if len(set(strings)) == 1:
        return strings[0]

    columns = [Counter({ch: 1}) for ch in strings[0]]
    for other in strings[1:]:
        columns = merge_columns(columns, other)

    result: list[str] = []
    for column in columns:
        gaps = column.get("", 0)
        filled = sorted(
            [(ch, n) for ch, n in column.items() if ch], key=lambda item: -item[1]
        )
        if not filled:
            continue

        top_char, top_count = filled[0]
        unique_top = sum(1 for _, n in filled if n == top_count) == 1

        if unique_top and top_count > gaps:
            pick = top_char
        elif de_bias and any(ch == "的" for ch, _ in filled):
            pick = "的"
        elif de_bias and any(ch in DE_CONFUSIONS for ch, _ in filled):
            pick = "的"
        else:
            # Conservative: a character any pass saw is kept. Vision drops real
            # characters more often than it invents them, so gaps never delete.
            pick = top_char

        if pick:
            result.append(pick)
    return "".join(result)


def vote(passes: list[dict[int, list[dict]]]) -> dict[int, list[dict]]:
    """Vote page by page across several passes.

    Lines are matched across passes by vertical position. A page whose vote
    comes out much shorter than its best input (line segmentation disagreed)
    falls back to that input instead.
    """
    if not passes:
        return {}
    reference = passes[0]
    pages: dict[int, list[dict]] = {}

    for page_no, lines in reference.items():
        others = [p.get(page_no, []) for p in passes[1:]]
        voted: list[dict] = []

        for line in lines:
            group = [line["t"]]
            for other in others:
                match = [x for x in other if abs(x["y"] - line["y"]) < 0.014]
                if len(match) == 1:
                    group.append(match[0]["t"])
            voted.append({**line, "t": vote_line(group)})

        voted_len = sum(len(x["t"]) for x in voted)
        best = max([lines] + others, key=lambda v: sum(len(x["t"]) for x in v))
        best_len = sum(len(x["t"]) for x in best)
        pages[page_no] = best if (best_len and voted_len < best_len * 0.85) else voted

    return pages
