"""Vision OCR engine wrapper.

The engine is a small Swift binary that renders PDF pages (or reads images)
and runs Apple's Vision framework, emitting one JSON object per text line.
This module locates it and normalises its output.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import threading

ENGINE_NAME = "ocrvision"
INSTALL_ROOT = os.path.expanduser("~/.local/share/applevision-ocr")


class EngineNotFound(RuntimeError):
    pass


def find_engine() -> str:
    """Locate the engine binary.

    Order: $APPLEVISION_OCR_ENGINE, the install root, the package's parent tree
    (source checkout), then $PATH.
    """
    env = os.environ.get("APPLEVISION_OCR_ENGINE")
    if env and os.path.isfile(env) and os.access(env, os.X_OK):
        return env

    here = os.path.dirname(os.path.abspath(__file__))
    candidates = [
        os.path.join(INSTALL_ROOT, ENGINE_NAME),
        os.path.join(here, ENGINE_NAME),
        os.path.join(os.path.dirname(here), ENGINE_NAME),
        os.path.join(os.path.dirname(here), "bin", ENGINE_NAME),
        os.path.join(os.path.dirname(os.path.dirname(here)), "bin", ENGINE_NAME),
    ]
    for c in candidates:
        if os.path.isfile(c) and os.access(c, os.X_OK):
            return c

    found = shutil.which(ENGINE_NAME)
    if found:
        return found

    raise EngineNotFound(
        "找不到识别引擎 ocrvision。\n"
        "请先运行 `make engine` 或 `make install` 编译安装。"
    )


def run(
    path: str,
    pages: str | None = None,
    scale: float = 4.5,
    rot: float = 0,
    langs: str = "zh-Hans,en-US",
    correct: bool = True,
    fast: bool = False,
    quiet: bool = False,
) -> list[dict]:
    """Run the engine over one file and return parsed line records.

    The engine reports progress on stderr as one ``page N`` line per page.
    It has to be forwarded as it arrives: capturing it in a pipe (the old
    behaviour) buffers it until the engine exits, which meant a 258-page run
    showed no progress at all until it finished.
    """
    cmd = [
        find_engine(),
        "--input", path,
        "--scale", str(scale),
        "--rot", str(rot),
        "--lang", langs,
    ]
    if pages:
        cmd += ["--pages", pages]
    if not correct:
        cmd.append("--no-correct")
    if fast:
        cmd.append("--fast")
    if quiet:
        cmd.append("--quiet")

    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    stderr_lines: list[str] = []

    def pump() -> None:
        for raw in iter(proc.stderr.readline, b""):  # type: ignore[union-attr]
            text = raw.decode("utf-8", "ignore").rstrip("\n")
            if not text:
                continue
            stderr_lines.append(text)
            if not quiet:
                print(text, file=sys.stderr, flush=True)

    reader = threading.Thread(target=pump, daemon=True)
    reader.start()
    stdout = proc.stdout.read() if proc.stdout else b""
    proc.wait()
    reader.join()

    if proc.returncode != 0:
        detail = "\n".join(stderr_lines[-20:])
        raise RuntimeError(
            f"引擎执行失败（退出码 {proc.returncode}）"
            + (f"\n{detail[:600]}" if detail else "")
        )

    out: list[dict] = []
    for line in stdout.decode("utf-8", "ignore").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return out


def page_count(path: str) -> int:
    """Return the number of pages in a PDF, or 1 for images.

    Used to resolve negative/relative page specs (``-10`` = last 10 pages)
    before handing a concrete page list to the engine.
    """
    proc = subprocess.run(
        [find_engine(), "--input", path, "--count"], capture_output=True
    )
    out = proc.stdout.decode("utf-8", "ignore").strip().splitlines()
    try:
        return max(1, int(out[0]))
    except (ValueError, IndexError):
        return 1


def group_pages(lines: list[dict]) -> dict[int, list[dict]]:
    """Group line records by page, ordered top-to-bottom then left-to-right."""
    pages: dict[int, list[dict]] = {}
    for line in lines:
        pages.setdefault(line["p"], []).append(line)
    for value in pages.values():
        value.sort(key=lambda item: (item["y"], item["x"]))
    return pages
