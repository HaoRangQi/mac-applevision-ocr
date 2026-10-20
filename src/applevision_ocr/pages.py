"""Page-spec parsing for the ``--pages`` option.

The grammar mirrors the engine's ``resolvePages`` so the same string works
whether it is parsed here or by the Swift engine:

    all / ""    every page
    1,3-5       comma-separated segments of single pages and ranges
    10--3       page 10 through the third page from the end
    -10         the last 10 pages

Out-of-range pages are dropped, reversed ranges are corrected, duplicates are
merged, and the result is sorted. Anything unparsable raises :class:`PageSpecError`
instead of silently selecting nothing (the old behaviour that made typos such
as ``1-5,10`` OCR zero pages).
"""

from __future__ import annotations

import re

_RANGE_RE = re.compile(r"^\s*(-?\d+)\s*-\s*(-?\d+)\s*$")
_SINGLE_RE = re.compile(r"^\s*(-?\d+)\s*$")


class PageSpecError(ValueError):
    """Raised when a page specification cannot be parsed."""


def _from_end(n: int, total: int) -> int:
    """Translate a negative index into a 1-based page number."""
    return total + 1 + n if n < 0 else n


def parse_page_spec(spec: str | None) -> list[tuple[int, int]]:
    """Parse a page spec into raw ``(start, end)`` ranges without clamping.

    Values are returned as given, so negative endpoints stay negative; use
    :func:`resolve_pages` to turn them into concrete page numbers.
    """
    if spec is None:
        return []
    text = str(spec).strip()
    if not text or text.lower() == "all":
        return []

    ranges: list[tuple[int, int]] = []
    for raw in text.split(","):
        token = raw.strip()
        if not token:
            continue
        m = _RANGE_RE.match(token)
        if m:
            ranges.append((int(m.group(1)), int(m.group(2))))
            continue
        m = _SINGLE_RE.match(token)
        if m:
            n = int(m.group(1))
            # A bare negative number means "the last N pages".
            ranges.append((n, 0) if n < 0 else (n, n))
            continue
        raise PageSpecError(f"invalid page token: {token!r} in {spec!r}")
    return ranges


def parse_pages(spec: str | None, total: int) -> list[int]:
    """Resolve a page spec into a sorted list of 1-based page numbers.

    ``total`` is the real page count of the document.
    """
    raw = parse_page_spec(spec)
    if not raw:
        return list(range(1, total + 1))

    picked: set[int] = set()
    for start, end in raw:
        if start < 0 or end < 0:
            lo = _from_end(start, total)
            hi = _from_end(end, total) if end else total
        else:
            lo, hi = start, end
        lo, hi = min(lo, hi), max(lo, hi)
        for page in range(lo, hi + 1):
            if 1 <= page <= total:
                picked.add(page)
    return sorted(picked)


def format_pages(pages: list[int]) -> str:
    """Render page numbers back into the compact comma/range form."""
    if not pages:
        return ""
    ordered = sorted(set(pages))
    chunks: list[str] = []
    run_start = previous = ordered[0]
    for page in ordered[1:]:
        if page == previous + 1:
            previous = page
            continue
        chunks.append(str(run_start) if run_start == previous else f"{run_start}-{previous}")
        run_start = previous = page
    chunks.append(str(run_start) if run_start == previous else f"{run_start}-{previous}")
    return ",".join(chunks)


def normalise_pages(spec: str | None, total: int) -> str:
    """Parse a spec, then re-render it in canonical form for the engine."""
    return format_pages(parse_pages(spec, total))
